/**
 * @description  Test class for OpportunityAlertEmailHandler. Covers each alert rule, the
 *               Won / Lost stages, the department filter, duplicate suppression and bulk
 *               (batched) email sending.
 * @author       Tharun N
 * @date         28-09-2026
 * @group        Opportunity
 * @see          OpportunityAlertEmailHandler
 */
@isTest
private class OpportunityAlertEmailHandlerTest {

    private static Integer idCounter = 1;

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
     * @description Builds an in-memory Opportunity with the given stage and amount, owned by
     *              the running user.
     */
    private static Opportunity opp(Id oppId, String stage, Decimal amount) {
        return new Opportunity(Id = oppId, Name = 'Alert Test Deal', StageName = stage,
            Amount = amount, CloseDate = Date.today().addDays(10), OwnerId = UserInfo.getUserId());
    }

    /**
     * @description Puts the running user in the department, so tests do not depend on the
     *              org's users or the Opportunity_Alert_Department_Head_Username label.
     */
    private static void useRunningUserAsDepartment() {
        OpportunityAlertEmailHandler.departmentUserIds = new Set<Id>{ UserInfo.getUserId() };
        OpportunityAlertEmailHandler.departmentUserIdsLoaded = true;
    }

    /**
     * @description Runs the rule evaluation for a single old -> new change of a department deal.
     */
    private static List<OpportunityAlertEmailHandler.AlertEmail> build(Opportunity oldOpp, Opportunity newOpp) {
        useRunningUserAsDepartment();
        return OpportunityAlertEmailHandler.buildAlertEmails(
            new List<Opportunity>{ newOpp }, new Map<Id, Opportunity>{ oldOpp.Id => oldOpp });
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

    @isTest
    static void highValueAmountChangeNotifiesDara() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Needs Analysis', 2000000), opp(oppId, 'Needs Analysis', 3000000));

        System.assertEquals(1, emails.size(), 'One email expected');
        System.assertEquals(labelEmails(System.Label.Opportunity_Alert_High_Value_Emails), recipients(emails),
            'High value label recipients expected');
    }

    @isTest
    static void highValueStageChangeNotifiesDara() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Needs Analysis', 3000000), opp(oppId, 'Demo Scheduled', 3000000));

        System.assertEquals(1, emails.size(), 'One email expected');
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
    static void amountDroppingBelowTwentyFiveLakhsStillNotifies() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Needs Analysis', 3000000), opp(oppId, 'Needs Analysis', 2000000));

        System.assertEquals(1, emails.size(), 'One email expected when a high value deal drops below 25 Lakhs');
        System.assertEquals(labelEmails(System.Label.Opportunity_Alert_High_Value_Emails), recipients(emails),
            'High value label recipients expected');
        System.assert(emails[0].message.getSubject().startsWith('High Value Deal Update'), 'High value subject expected');
    }

    @isTest
    static void amountChangeBelowTwentyFiveLakhsSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Needs Analysis', 2000000), opp(oppId, 'Needs Analysis', 2200000)).size(), 'No email expected');
    }

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
    static void closedWonBelowTwentyFiveLakhsSendsNothing() {
        Id oppId = fakeOppId();

        System.assertEquals(0, build(opp(oppId, 'Negotiation / Review', 1500000), opp(oppId, 'Closed Won', 1500000)).size(),
            'Closed Won is not a Won stage, so no email expected');
    }

    @isTest
    static void closedWonAtHighValueSendsHighValueUpdate() {
        Id oppId = fakeOppId();
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(opp(oppId, 'Negotiation / Review', 3000000), opp(oppId, 'Closed Won', 3000000));

        System.assertEquals(1, emails.size(), 'One email expected');
        System.assertEquals(labelEmails(System.Label.Opportunity_Alert_High_Value_Emails), recipients(emails),
            'Only High Value label recipients expected');
        System.assert(emails[0].message.getSubject().startsWith('High Value Deal Update'), 'High value subject expected');
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

    @isTest
    static void dealOwnedOutsideDepartmentSendsNothing() {
        Id oppId = fakeOppId();
        Opportunity newOpp = opp(oppId, 'Invoiced', 3000000);
        newOpp.OwnerId = fakeId(User.SObjectType);

        System.assertEquals(0, build(opp(oppId, 'Negotiation / Review', 3000000), newOpp).size(),
            'No email expected for a deal owned outside the department');
    }

    @isTest
    static void departmentFilterIsSkippedWhenHeadIsNotFound() {
        OpportunityAlertEmailHandler.departmentUserIds = null;
        OpportunityAlertEmailHandler.departmentUserIdsLoaded = true;

        Id oppId = fakeOppId();
        Opportunity newOpp = opp(oppId, 'Invoiced', 500000);
        newOpp.OwnerId = fakeId(User.SObjectType);

        System.assertEquals(1, OpportunityAlertEmailHandler.buildAlertEmails(
            new List<Opportunity>{ newOpp },
            new Map<Id, Opportunity>{ oppId => opp(oppId, 'Negotiation / Review', 500000) }).size(),
            'Alert should still be sent when the department head is not found');
    }

    @isTest
    static void departmentUsersAreNotQueriedWhenNoRuleMatches() {
        Id oppId = fakeOppId();
        OpportunityAlertEmailHandler.buildAlertEmails(
            new List<Opportunity>{ opp(oppId, 'Demo Scheduled', 800000) },
            new Map<Id, Opportunity>{ oppId => opp(oppId, 'Needs Analysis', 500000) });

        System.assert(!OpportunityAlertEmailHandler.departmentUserIdsLoaded, 'Users should only be queried when a rule matches');
    }

    @isTest
    static void departmentUsersAreQueriedOncePerTransaction() {
        for (Integer i = 0; i < 2; i++) {
            Id oppId = fakeOppId();
            Integer queriesBefore = Limits.getQueries();
            OpportunityAlertEmailHandler.buildAlertEmails(
                new List<Opportunity>{ opp(oppId, 'Closed Lost', 500000) },
                new Map<Id, Opportunity>{ oppId => opp(oppId, 'Negotiation / Review', 500000) });

            if (i == 1) {
                System.assertEquals(queriesBefore, Limits.getQueries(), 'Department users should be cached after the first run');
            }
        }
        System.assert(OpportunityAlertEmailHandler.departmentUserIdsLoaded, 'Department users should be loaded');
    }

    @isTest
    static void departmentIncludesManagerChainAndRoleTree() {
        Id bossRole = fakeId(UserRole.SObjectType);
        Id headRole = fakeId(UserRole.SObjectType);
        Id childRole = fakeId(UserRole.SObjectType);
        Id grandchildRole = fakeId(UserRole.SObjectType);
        Id otherRole = fakeId(UserRole.SObjectType);
        List<UserRole> roles = new List<UserRole>{
            new UserRole(Id = bossRole),
            new UserRole(Id = headRole, ParentRoleId = bossRole),
            new UserRole(Id = childRole, ParentRoleId = headRole),
            new UserRole(Id = grandchildRole, ParentRoleId = childRole),
            new UserRole(Id = otherRole, ParentRoleId = bossRole)
        };

        Id boss = fakeId(User.SObjectType);
        Id head = fakeId(User.SObjectType);
        Id directReport = fakeId(User.SObjectType);
        Id indirectReport = fakeId(User.SObjectType);
        Id sameRoleUser = fakeId(User.SObjectType);
        Id childRoleUser = fakeId(User.SObjectType);
        Id grandchildRoleUser = fakeId(User.SObjectType);
        Id outsider = fakeId(User.SObjectType);
        List<User> users = new List<User>{
            new User(Id = boss, Username = 'boss@alert.test', UserRoleId = bossRole),
            new User(Id = head, Username = 'head@alert.test', ManagerId = boss, UserRoleId = headRole),
            new User(Id = directReport, Username = 'direct@alert.test', ManagerId = head),
            new User(Id = indirectReport, Username = 'indirect@alert.test', ManagerId = directReport, UserRoleId = otherRole),
            new User(Id = sameRoleUser, Username = 'same@alert.test', UserRoleId = headRole),
            new User(Id = childRoleUser, Username = 'child@alert.test', UserRoleId = childRole),
            new User(Id = grandchildRoleUser, Username = 'grandchild@alert.test', UserRoleId = grandchildRole),
            new User(Id = outsider, Username = 'outsider@alert.test', ManagerId = boss, UserRoleId = otherRole)
        };

        System.assertEquals(
            new Set<Id>{ head, directReport, indirectReport, sameRoleUser, childRoleUser, grandchildRoleUser },
            OpportunityAlertEmailHandler.findDepartmentUsers('head@alert.test', users, roles),
            'Head, reports and role tree expected; the head\'s boss and other teams excluded');
    }

    @isTest
    static void departmentUsesManagerChainWhenHeadHasNoRole() {
        Id head = fakeId(User.SObjectType);
        Id directReport = fakeId(User.SObjectType);
        Id noRoleUser = fakeId(User.SObjectType);
        List<User> users = new List<User>{
            new User(Id = head, Username = 'head@alert.test'),
            new User(Id = directReport, Username = 'direct@alert.test', ManagerId = head),
            new User(Id = noRoleUser, Username = 'norole@alert.test')
        };

        System.assertEquals(new Set<Id>{ head, directReport },
            OpportunityAlertEmailHandler.findDepartmentUsers('head@alert.test', users, new List<UserRole>()),
            'Users without a role must not match a head without a role');
    }

    @isTest
    static void departmentIsNullWhenHeadIsNotFound() {
        List<User> users = new List<User>{ new User(Id = fakeId(User.SObjectType), Username = 'someone@alert.test') };

        System.assertEquals(null, OpportunityAlertEmailHandler.findDepartmentUsers('head@alert.test', users, new List<UserRole>()),
            'Null expected when the head is not found');
    }

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
        useRunningUserAsDepartment();

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

        System.assertEquals(0, OpportunityAlertEmailHandler.sendInvocationCount, 'No email calls expected');
    }

    /**
     * @description Inserts a real open deal so emails and activities can be saved against it.
     */
    private static Opportunity insertDeal() {
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
            Amount                 = 500000,
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
        return deal;
    }

    @isTest
    static void sentEmailIsLoggedAsActivityOnDeal() {
        Opportunity deal = insertDeal();

        Opportunity closedDeal = deal.clone(true, true);
        closedDeal.StageName = 'Closed Lost';
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(deal, closedDeal);

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
        Opportunity deal = insertDeal();

        Opportunity closedDeal = deal.clone(true, true);
        closedDeal.StageName = 'Closed Lost';
        List<OpportunityAlertEmailHandler.AlertEmail> emails = build(deal, closedDeal);
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
        Opportunity deal = insertDeal();
        useRunningUserAsDepartment();

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
}