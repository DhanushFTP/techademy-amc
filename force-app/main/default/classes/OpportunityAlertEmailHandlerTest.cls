/**
 * @description  Test class for OpportunityAlertEmailHandler. Covers each alert rule, Won / Lost
 *               by Forecast Category, the 25 Lakhs crossing, inserted deals, the B2B filter,
 *               duplicate suppression and bulk (batched) email sending.
 * @author       Tharun N
 * @date         28-09-2026
 * @group        Opportunity
 * @see          OpportunityAlertEmailHandler
 */
@isTest
private class OpportunityAlertEmailHandlerTest {

    private static Integer idCounter = 1;

    // Forecast Category of each stage, as configured in the org (loaded once per test)
    private static Map<String, String> forecastByStage;

    /**
     * @description Generates a unique fake record Id so rules can be tested without DML.
     */
    private static Id fakeId(Schema.SObjectType objectType) {
        String num = String.valueOf(idCounter++);
        return (Id) (objectType.getDescribe().getKeyPrefix() + '0'.repeat(12 - num.length()) + num);
    }

    /**
     * @description Generates a unique fake Opportunity Id.
     */
    private static Id fakeOppId() {
        return fakeId(Opportunity.SObjectType);
    }

    /**
     * @description Returns the org's Forecast Category for a stage, as Salesforce sets it on save.
     */
    private static String forecastCategory(String stage) {
        if (forecastByStage == null) {
            forecastByStage = new Map<String, String>();
            for (OpportunityStage s : [SELECT MasterLabel, ForecastCategoryName FROM OpportunityStage]) {
                forecastByStage.put(s.MasterLabel, s.ForecastCategoryName);
            }
        }
        return forecastByStage.get(stage);
    }

    /**
     * @description Builds an in-memory B2B Opportunity with the given stage and amount, owned by
     *              the running user.
     */
    private static Opportunity opp(Id oppId, String stage, Decimal amount) {
        return opp(oppId, stage, amount, 'B2B');
    }

    /**
     * @description Builds an in-memory Opportunity with the given owner line of business. The
     *              Forecast Category is set from the stage, as on save. LOB__c is a formula
     *              field, so the record is built from JSON to set it.
     */
    private static Opportunity opp(Id oppId, String stage, Decimal amount, String lob) {
        return (Opportunity) JSON.deserialize(JSON.serialize(new Map<String, Object>{
            'Id'                   => oppId,
            'Name'                 => 'Alert Test Deal',
            'StageName'            => stage,
            'ForecastCategoryName' => forecastCategory(stage),
            'Amount'               => amount,
            'CloseDate'            => Date.today().addDays(10),
            'OwnerId'              => UserInfo.getUserId(),
            'LOB__c'               => lob
        }), Opportunity.class);
    }

    /**
     * @description Copies a deal with a new stage and the Forecast Category Salesforce would set.
     */
    private static Opportunity withStage(Opportunity deal, String stage) {
        Opportunity moved = deal.clone(true, true);
        moved.StageName = stage;
        moved.ForecastCategoryName = forecastCategory(stage);
        return moved;
    }

    /**
     * @description Runs the rule evaluation for a single old -> new change of a deal.
     */
    private static List<OpportunityAlertEmailHandler.AlertEmail> build(Opportunity oldOpp, Opportunity newOpp) {
        return OpportunityAlertEmailHandler.buildAlertEmails(
            new List<Opportunity>{ newOpp }, new Map<Id, Opportunity>{ oldOpp.Id => oldOpp });
    }

    /**
     * @description Runs the rule evaluation for a single inserted deal.
     */
    private static List<OpportunityAlertEmailHandler.AlertEmail> buildInsert(Opportunity newOpp) {
        return OpportunityAlertEmailHandler.buildAlertEmails(new List<Opportunity>{ newOpp }, null);
    }

    /**
     * @description Collects all To addresses across the given emails.
     */
    private static Set<String> recipients(List<OpportunityAlertEmailHandler.AlertEmail> emails) {
        Set<String> result = new Set<String>();
        for (OpportunityAlertEmailHandler.AlertEmail a : emails) {
            result.addAll(a.message.getToAddresses());
        }
        return result;
    }

    /**
     * @description Parses a custom label value into a set of trimmed email addresses.
     */
    private static Set<String> labelEmails(String labelValue) {
        Set<String> result = new Set<String>();
        for (String e : labelValue.split('[,;]')) {
            if (String.isNotBlank(e)) result.add(e.trim());
        }
        return result;
    }

    // ---------------- 25 Lakhs crossing ----------------

    @isTest
    static void highValueAmountChangeNotifiesDara() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Needs Analysis', 2000000), opp(oppId, 'Needs Analysis', 3000000));

        System.assertEquals(1, emails.size(), 'One email expected when the amount reaches 25 Lakhs');
        System.assertEquals(labelEmails(System.Label.Opportunity_Alert_High_Value_Emails), recipients(emails),
            'High value label recipients expected');
        System.assert(emails[0].message.getSubject().startsWith('High Value Deal Update'), 'High value subject expected');
    }

    @isTest
    static void highValueStageChangeSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Needs Analysis', 3000000), opp(oppId, 'Demo Scheduled', 3000000)).size(),
            'No email expected for a stage change on an open deal');
    }

    @isTest
    static void highValueWithoutStageOrAmountChangeSendsNothing() {
        Id oppId = fakeOppId();
        Opportunity newOpp = opp(oppId, 'Needs Analysis', 3000000);
        newOpp.Name = 'Renamed Deal';

        System.assertEquals(0, build(opp(oppId, 'Needs Analysis', 3000000), newOpp).size(), 'No email expected');
    }

    @isTest
    static void amountOfExactlyTwentyFiveLakhsIsHighValue() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Needs Analysis', 2400000), opp(oppId, 'Needs Analysis', 2500000));

        System.assertEquals(1, emails.size(), 'One email expected at exactly 25 Lakhs');
    }

    @isTest
    static void amountChangeAboveTwentyFiveLakhsSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Solution Proposed', 4300000), opp(oppId, 'Solution Proposed', 3800000)).size(),
            'No email expected while the amount stays at 25 Lakhs or above');
    }

    @isTest
    static void amountDroppingBelowTwentyFiveLakhsStillNotifies() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Needs Analysis', 3000000), opp(oppId, 'Needs Analysis', 2000000));

        System.assertEquals(1, emails.size(), 'One email expected when a high value deal drops below 25 Lakhs');
        System.assertEquals(labelEmails(System.Label.Opportunity_Alert_High_Value_Emails), recipients(emails),
            'High value label recipients expected');
        System.assert(emails[0].message.getSubject().startsWith('High Value Deal Update'), 'High value subject expected');
    }

    @isTest
    static void amountFallingFurtherBelowTwentyFiveLakhsSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Needs Analysis', 2000000), opp(oppId, 'Needs Analysis', 1500000)).size(),
            'No email expected once the amount is already below 25 Lakhs');
    }

    @isTest
    static void amountChangeBelowTwentyFiveLakhsSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Needs Analysis', 2000000), opp(oppId, 'Needs Analysis', 2200000)).size(), 'No email expected');
    }

    // ---------------- Won / Lost ----------------

    @isTest
    static void wonStageAtExactlyTenLakhsNotifiesTenLakhRecipients() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Negotiation / Review', 1000000), opp(oppId, 'Invoiced', 1000000));

        Set<String> expected = labelEmails(System.Label.Opportunity_Alert_Closed_Won_10L_Emails);
        expected.addAll(labelEmails(System.Label.Opportunity_Alert_Closed_Deal_Emails));

        System.assertEquals(1, emails.size(), 'One combined email expected');
        System.assertEquals(expected, recipients(emails), '10L + Closed Deal label recipients expected at exactly 10 Lakhs');
    }

    @isTest
    static void closedLostAboveTenLakhsNotifiesTenLakhRecipients() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Negotiation / Review', 1500000), opp(oppId, 'Closed Lost', 1500000));

        Set<String> expected = labelEmails(System.Label.Opportunity_Alert_Closed_Won_10L_Emails);
        expected.addAll(labelEmails(System.Label.Opportunity_Alert_Closed_Deal_Emails));

        System.assertEquals(1, emails.size(), 'One combined email expected');
        System.assertEquals(expected, recipients(emails), '10L + Closed Deal label recipients expected');
        System.assert(emails[0].message.getSubject().startsWith('Deal Lost'), 'Lost subject expected');
    }

    @isTest
    static void wonStageAboveTenLakhsNotifiesTenLakhRecipients() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Negotiation / Review', 1500000), opp(oppId, 'Invoiced', 1500000));

        Set<String> expected = labelEmails(System.Label.Opportunity_Alert_Closed_Won_10L_Emails);
        expected.addAll(labelEmails(System.Label.Opportunity_Alert_Closed_Deal_Emails));

        System.assertEquals(1, emails.size(), 'One combined email expected');
        System.assertEquals(expected, recipients(emails), '10L + Closed Deal label recipients expected');
        System.assert(emails[0].message.getSubject().startsWith('Deal Won'), 'Won subject expected');
    }

    @isTest
    static void wonStageBelowTenLakhsNotifiesDaraOnly() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Negotiation / Review', 500000), opp(oppId, 'Invoiced', 500000));

        System.assertEquals(1, emails.size(), 'One email expected');
        System.assertEquals(labelEmails(System.Label.Opportunity_Alert_Closed_Deal_Emails), recipients(emails),
            'Only Closed Deal label recipients expected');
    }

    @isTest
    static void highValueDealMovedToWonNotifiesAllRecipients() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Negotiation / Review', 3000000), opp(oppId, 'Invoiced', 3000000));

        Set<String> expected = labelEmails(System.Label.Opportunity_Alert_High_Value_Emails);
        expected.addAll(labelEmails(System.Label.Opportunity_Alert_Closed_Won_10L_Emails));
        expected.addAll(labelEmails(System.Label.Opportunity_Alert_Closed_Deal_Emails));

        System.assertEquals(1, emails.size(), 'One combined email expected');
        System.assertEquals(expected, recipients(emails), 'High Value + 10L + Closed Deal label recipients expected');
        System.assert(emails[0].message.getSubject().startsWith('Deal Won'), 'Won subject expected');
    }

    @isTest
    static void everyWonStageSendsDealWonEmail() {
        for (String stage : new List<String>{ 'Invoiced', 'Invoiced - Delivery Pending', 'Invoiced - Delivery in Progress', 'Overdue', 'Collected' }) {
            Id oppId = fakeOppId();
            List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Negotiation / Review', 500000), opp(oppId, stage, 500000));

            System.assertEquals(1, emails.size(), 'One email expected for ' + stage);
            System.assert(emails[0].message.getSubject().startsWith('Deal Won'), 'Won subject expected for ' + stage);
        }
    }

    @isTest
    static void everyLostStageSendsDealLostEmail() {
        for (String stage : new List<String>{ 'Campaign', 'Closed Lost', 'Closed-Lost to Competition', 'Cold', 'Deferred', 'Solution Declined', 'Training Cancelled' }) {
            Id oppId = fakeOppId();
            List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Negotiation / Review', 500000), opp(oppId, stage, 500000));

            System.assertEquals(1, emails.size(), 'One email expected for ' + stage);
            System.assert(emails[0].message.getSubject().startsWith('Deal Lost'), 'Lost subject expected for ' + stage);
        }
    }

    @isTest
    static void commitToClosedSendsDealWon() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Delivery Completed', 500000), opp(oppId, 'Invoiced', 500000));

        System.assertEquals(1, emails.size(), 'One email expected when the deal moves from Commit to Closed');
        System.assert(emails[0].message.getSubject().startsWith('Deal Won'), 'Won subject expected');
    }

    @isTest
    static void forecastCategoryOverriddenToClosedSendsDealWon() {
        Id oppId = fakeOppId();
        Opportunity newOpp = opp(oppId, 'Delivery Completed', 500000);
        newOpp.ForecastCategoryName = 'Closed';

        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Delivery Completed', 500000), newOpp);

        System.assertEquals(1, emails.size(), 'Won follows the Forecast Category, as in the forecast sheet');
        System.assert(emails[0].message.getSubject().startsWith('Deal Won'), 'Won subject expected');
    }

    @isTest
    static void movingBetweenWonStagesSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Invoiced', 3000000), opp(oppId, 'Collected', 3000000)).size(),
            'Only one Won email expected per deal: no email between Won stages');
    }

    @isTest
    static void movingBetweenLostStagesSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Cold', 3000000), opp(oppId, 'Closed Lost', 3000000)).size(),
            'Only one Lost email expected per deal: no email between Lost stages');
    }

    @isTest
    static void amountChangeOnWonDealSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Collected', 2000000), opp(oppId, 'Collected', 3000000)).size(),
            'No amount email expected once the deal is Won');
    }

    @isTest
    static void amountChangeOnLostDealSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Closed Lost', 2000000), opp(oppId, 'Closed Lost', 3000000)).size(),
            'No amount email expected once the deal is Lost');
    }

    @isTest
    static void wonDealMovedToLostSendsDealLost() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Collected', 500000), opp(oppId, 'Training Cancelled', 500000));

        System.assertEquals(1, emails.size(), 'One email expected when a Won deal becomes Lost');
        System.assert(emails[0].message.getSubject().startsWith('Deal Lost'), 'Lost subject expected');
    }

    @isTest
    static void reopenedWonDealSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Invoiced', 3000000), opp(oppId, 'Delivery Completed', 3000000)).size(),
            'No email expected when a Won deal is reopened without crossing 25 Lakhs');
    }

    @isTest
    static void closedWonBelowTwentyFiveLakhsSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Negotiation / Review', 1500000), opp(oppId, 'Closed Won', 1500000)).size(),
            'Closed Won is Commit, not Won, so no email expected');
    }

    @isTest
    static void closedWonAtHighValueSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Negotiation / Review', 3000000), opp(oppId, 'Closed Won', 3000000)).size(),
            'Closed Won is Commit, not Won, and the amount did not cross 25 Lakhs, so no email expected');
    }

    @isTest
    static void closedLostNotifiesDara() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Negotiation / Review', 500000), opp(oppId, 'Closed Lost', 500000));

        System.assertEquals(1, emails.size(), 'One email expected');
        System.assertEquals(labelEmails(System.Label.Opportunity_Alert_Closed_Deal_Emails), recipients(emails),
            'Only Closed Deal label recipients expected below 10 Lakhs');
        System.assert(emails[0].message.getSubject().startsWith('Deal Lost'), 'Lost subject expected');
    }

    @isTest
    static void closedLostToCompetitionNotifiesDara() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Negotiation / Review', 500000), opp(oppId, 'Closed-Lost to Competition', 500000));

        System.assertEquals(1, emails.size(), 'One email expected');
    }

    @isTest
    static void lowValueNonClosingChangeSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Needs Analysis', 500000), opp(oppId, 'Demo Scheduled', 800000)).size(), 'No email expected');
    }

    // ---------------- Inserted deals ----------------

    @isTest
    static void dealCreatedAtHighValueSendsHighValueEmail() {
        List<OpportunityAlertEmailHandler.AlertEmail> emails = buildInsert(opp(fakeOppId(), 'Needs Analysis', 3000000));

        System.assertEquals(1, emails.size(), 'One email expected for a deal created at 25 Lakhs or above');
        System.assertEquals(labelEmails(System.Label.Opportunity_Alert_High_Value_Emails), recipients(emails),
            'High value label recipients expected');
        System.assert(emails[0].message.getSubject().startsWith('High Value Deal Update'), 'High value subject expected');
    }

    @isTest
    static void dealCreatedBelowHighValueSendsNothing() {
        System.assertEquals(0, buildInsert(opp(fakeOppId(), 'Needs Analysis', 2000000)).size(), 'No email expected');
    }

    @isTest
    static void dealCreatedAsWonSendsDealWon() {
        List<OpportunityAlertEmailHandler.AlertEmail> emails = buildInsert(opp(fakeOppId(), 'Invoiced', 500000));

        System.assertEquals(1, emails.size(), 'One email expected for a deal created as Won');
        System.assertEquals(labelEmails(System.Label.Opportunity_Alert_Closed_Deal_Emails), recipients(emails),
            'Only Closed Deal label recipients expected below 10 Lakhs');
        System.assert(emails[0].message.getSubject().startsWith('Deal Won'), 'Won subject expected');
    }

    @isTest
    static void dealCreatedInLostStageSendsNothing() {
        System.assertEquals(0, buildInsert(opp(fakeOppId(), 'Campaign', 3000000)).size(),
            'No email expected for a deal created in a Lost stage');
    }

    @isTest
    static void dealCreatedThenUpdatedInSameTransactionIsEmailedOnce() {
        Id oppId = fakeOppId();
        System.assertEquals(1, buildInsert(opp(oppId, 'Needs Analysis', 3000000)).size(), 'One email expected on insert');

        System.assertEquals(0, build(opp(oppId, 'Needs Analysis', 3000000), opp(oppId, 'Needs Analysis', 2000000)).size(),
            'No second email expected in the same transaction');
    }

    // ---------------- B2B filter ----------------

    @isTest
    static void b2aDealSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Negotiation / Review', 3000000, 'B2A'), opp(oppId, 'Invoiced', 3000000, 'B2A')).size(),
            'No email expected for a B2A deal');
    }

    @isTest
    static void dealWithoutLobSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Negotiation / Review', 3000000, null), opp(oppId, 'Invoiced', 3000000, null)).size(),
            'No email expected when the owner has no line of business');
        System.assertEquals(0, buildInsert(opp(fakeOppId(), 'Needs Analysis', 3000000, null)).size(),
            'No email expected for a new deal when the owner has no line of business');
    }

    // ---------------- Duplicates and bulk ----------------

    @isTest
    static void sameDealIsNotEmailedTwiceInOneTransaction() {
        Id oppId = fakeOppId();
        build(opp(oppId, 'Negotiation / Review', 500000), opp(oppId, 'Closed Lost', 500000));

        System.assertEquals(0, build(opp(oppId, 'Negotiation / Review', 500000), opp(oppId, 'Closed Lost', 500000)).size(),
            'Duplicate email should be suppressed');
    }

    @isTest
    static void sameDealIsEmailedAgainWhenSaveIsRetried() {
        Id oppId = fakeOppId();
        build(opp(oppId, 'Negotiation / Review', 500000), opp(oppId, 'Closed Lost', 500000));

        // Limit usage lower than after the previous run = the save was rolled back and retried
        OpportunityAlertEmailHandler.emailInvocationsSnapshot = Limits.getEmailInvocations() + 1;

        System.assertEquals(1, build(opp(oppId, 'Negotiation / Review', 500000), opp(oppId, 'Closed Lost', 500000)).size(),
            'Email should be built again when the save is retried');
    }

    @isTest
    static void bulkUpdateSendsEmailsInBatches() {
        List<Opportunity> newOpps = new List<Opportunity>();
        Map<Id, Opportunity> oldMap = new Map<Id, Opportunity>();
        for (Integer i = 0; i < 250; i++) {
            Id oppId = fakeOppId();
            oldMap.put(oppId, opp(oppId, 'Negotiation / Review', 500000));
            newOpps.add(opp(oppId, 'Closed Lost', 500000));
        }

        Test.startTest();
        OpportunityAlertEmailHandler.handleAfterUpdate(newOpps, oldMap);
        Test.stopTest();

        // Sandboxes often have deliverability off; the handler must then skip sending without throwing
        Boolean canSendEmail = true;
        try {
            Messaging.reserveSingleEmailCapacity(1);
        } catch (Exception e) {
            canSendEmail = false;
        }

        // 250 emails / 100 per call = 3 sendEmail calls, within the 10-call transaction limit
        System.assertEquals(canSendEmail ? 3 : 0, OpportunityAlertEmailHandler.sendInvocationCount,
            'Emails should be sent in 3 batches, or skipped safely when email is disabled');
    }

    @isTest
    static void emptyInputSendsNothing() {
        OpportunityAlertEmailHandler.handleAfterUpdate(new List<Opportunity>(), new Map<Id, Opportunity>());
        OpportunityAlertEmailHandler.handleAfterUpdate(null, null);
        OpportunityAlertEmailHandler.handleAfterInsert(new List<Opportunity>());
        OpportunityAlertEmailHandler.handleAfterInsert(null);

        System.assertEquals(0, OpportunityAlertEmailHandler.sendInvocationCount, 'No email calls expected');
    }

    // ---------------- Saved deals ----------------

    /**
     * @description Sets the running user's line of business to B2B, so deals they own are in
     *              scope. The deploying user may have no LOB, so tests must not rely on it.
     */
    private static void makeRunningUserB2B() {
        // User is a setup object: updated inside runAs to avoid mixed DML with the deal inserts
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = UserInfo.getUserId(), LOB__c = 'B2B');
        }
    }

    /**
     * @description Inserts a real open deal owned by a B2B user, so emails and activities can be
     *              saved against it. Returns it with its Forecast Category and LOB__c.
     */
    private static Opportunity insertDeal(Decimal amount) {
        makeRunningUserB2B();
        Account acct = new Account(Name = 'Alert Test Account');
        insert acct;
        Contact con = new Contact(LastName = 'Alert Test Contact');
        insert con;

        Opportunity deal = new Opportunity(
            Name                   = 'Alert Activity Deal',
            OwnerId                = UserInfo.getUserId(),
            AccountId              = acct.Id,
            Contact__c             = con.Id,
            Expected_Start_Date__c = Date.today().addDays(1),
            End_Date__c            = Date.today().addDays(2),
            CSDM_Lead__c           = 'Lishika',
            Amount                 = amount,
            StageName              = 'Needs Analysis',
            CloseDate              = Date.today().addDays(20),
            Pipeline__c            = 'Deal Pipeline',
            Product__c             = 'Techademy',
            Solution_Manager__c    = 'Sree Priyanka',
            Technical_Architect__c = 'Sameer',
            Delivery_CSM__c        = 'Aathif Fahad K',
            Mode__c                = 'Platform Only',
            PO_Status__c           = 'Pending',
            Line_of_Business__c    = 'Techademy: LMS Only'
        );
        insert deal;
        return [
            SELECT Id, Name, StageName, ForecastCategoryName, Amount, CloseDate, OwnerId, LOB__c
            FROM Opportunity WHERE Id = :deal.Id
        ];
    }

    @isTest
    static void sentEmailIsLoggedAsActivityOnDeal() {
        Opportunity deal = insertDeal(500000);
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(deal, withStage(deal, 'Closed Lost'));

        Test.startTest();
        List<OpportunityAlertEmailHandler.AlertEmail> notLogged = OpportunityAlertEmailHandler.logEmailActivities(emails);
        Test.stopTest();

        List<EmailMessage> activities = [
            SELECT Subject, ToAddress, Status FROM EmailMessage WHERE RelatedToId = :deal.Id
        ];
        System.assertEquals(1, activities.size(), 'Email should be logged as an activity on the deal');
        System.assert(activities[0].Subject.startsWith('Deal Lost'), 'Activity subject should match the email');
        System.assertEquals('3', activities[0].Status, 'Activity should be marked as Sent');
        System.assertEquals(0, notLogged.size(), 'No logging failure expected');
    }

    @isTest
    static void failedAlertIsRecordedOnDeal() {
        Opportunity deal = insertDeal(500000);
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(deal, withStage(deal, 'Closed Lost'));
        emails[0].failureReason = 'Email not sent - test failure';

        Test.startTest();
        OpportunityAlertEmailHandler.logFailedAlerts(emails);
        Test.stopTest();

        System.assertEquals(1, OpportunityAlertEmailHandler.failedAlertCount, 'Failed alert should be counted');
        // The task insert is best effort (org task rules may reject it), so only check what was saved
        for (Task failure : [SELECT Subject, Description FROM Task WHERE WhatId = :deal.Id]) {
            System.assert(failure.Subject.startsWith('Deal alert email issue'), 'Task subject should flag the alert issue');
            System.assert(failure.Description.contains('test failure'), 'Task should hold the failure reason');
        }
    }

    @isTest
    static void dealUpdateThroughTriggerSavesAlertOnDeal() {
        Opportunity deal = insertDeal(500000);

        Test.startTest();
        deal.Amount = 3000000;
        update deal;
        Test.stopTest();

        Integer logged = [SELECT COUNT() FROM EmailMessage WHERE RelatedToId = :deal.Id];
        // Sandboxes often have deliverability off; the alert must then be recorded as failed instead
        System.assert(logged == 1 || OpportunityAlertEmailHandler.failedAlertCount > 0,
            'Alert should be saved on the deal as an email, or recorded as failed');
        System.assertEquals(OpportunityAlertEmailHandler.sentEmailCount > 0 ? 1 : 0, logged,
            'A sent alert email should be logged exactly once on the deal');
    }

    @isTest
    static void dealInsertThroughTriggerSavesAlertOnDeal() {
        Test.startTest();
        Opportunity deal = insertDeal(3000000);
        Test.stopTest();

        Integer logged = [SELECT COUNT() FROM EmailMessage WHERE RelatedToId = :deal.Id];
        // Sandboxes often have deliverability off; the alert must then be recorded as failed instead
        System.assert(logged == 1 || OpportunityAlertEmailHandler.failedAlertCount > 0,
            'Alert should be saved on the new deal as an email, or recorded as failed');
        System.assertEquals(OpportunityAlertEmailHandler.sentEmailCount > 0 ? 1 : 0, logged,
            'A sent alert email should be logged exactly once on the new deal');
    }
}