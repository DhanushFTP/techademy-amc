/***************************************************************
 *  Class Name   : AccountBusinessTypeHandlerTest
 *  Company      : Fingertipplus
 *  Author       : Dhanush
 *  Tests        : AccountBusinessTypeHandler
 *  Description  : Test class for AccountBusinessTypeHandler.
 *                 - Covers the 2-financial-year rule (FY boundaries, same-FY wins), backdated wins,
 *                   several wins on one account in one save, and the trigger path.
 ***************************************************************/
@isTest
private class AccountBusinessTypeHandlerTest {

    private static final Date CLOSE_DATE = Date.newInstance(2026, 11, 3);
    private static Integer idCounter = 1;

    private static Id fakeAccountId() {
        String num = String.valueOf(idCounter++);
        return (Id) (Account.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(12 - num.length()) + num);
    }

    /**
     * @description Classifies one won deal closing on closeDate for an account last billed on lastBilled.
     *              Returns the account, or null if the handler left it unchanged.
     */
    private static Account classifyOne(Date lastBilled, Date closeDate) {
        Account acc = new Account(Id = fakeAccountId(), Last_Billed_Date__c = lastBilled);
        List<Account> changed = AccountBusinessTypeHandler.classify(
            new List<Opportunity>{ new Opportunity(AccountId = acc.Id, CloseDate = closeDate) },
            new Map<Id, Account>{ acc.Id => acc });
        return changed.isEmpty() ? null : changed[0];
    }

    @isTest
    static void neverBilledIsNewBusiness() {
        Account acc = classifyOne(null, CLOSE_DATE);
        Assert.areEqual(AccountBusinessTypeHandler.NEW_BUSINESS, acc.Business_Type__c);
        Assert.areEqual(CLOSE_DATE, acc.Last_Billed_Date__c);
    }

    // CLOSE_DATE is in FY 2026-27, so the 2 prior FYs are 2024-25 and 2025-26

    @isTest
    static void billedLastFyIsExisting() {
        Account acc = classifyOne(Date.newInstance(2025, 6, 1), CLOSE_DATE);
        Assert.areEqual(AccountBusinessTypeHandler.EXISTING, acc.Business_Type__c);
        Assert.areEqual(CLOSE_DATE, acc.Last_Billed_Date__c);
    }

    @isTest
    static void billedAtStartOfTwoFysAgoIsExisting() {
        // 1 Apr 2024 = first day of FY 2024-25 (31 months back, but still inside the 2 FYs)
        Account acc = classifyOne(Date.newInstance(2024, 4, 1), CLOSE_DATE);
        Assert.areEqual(AccountBusinessTypeHandler.EXISTING, acc.Business_Type__c);
    }

    @isTest
    static void billedThreeFysAgoIsNewBusiness() {
        // 31 Mar 2024 = last day of FY 2023-24
        Account acc = classifyOne(Date.newInstance(2024, 3, 31), CLOSE_DATE);
        Assert.areEqual(AccountBusinessTypeHandler.NEW_BUSINESS, acc.Business_Type__c);
    }

    @isTest
    static void billedEarlierSameFyKeepsBusinessType() {
        Account acc = new Account(Id = fakeAccountId(), Last_Billed_Date__c = Date.newInstance(2026, 5, 1),
            Business_Type__c = AccountBusinessTypeHandler.NEW_BUSINESS);
        List<Account> changed = AccountBusinessTypeHandler.classify(
            new List<Opportunity>{ new Opportunity(AccountId = acc.Id, CloseDate = CLOSE_DATE) },
            new Map<Id, Account>{ acc.Id => acc });
        Assert.areEqual(AccountBusinessTypeHandler.NEW_BUSINESS, changed[0].Business_Type__c);
        Assert.areEqual(CLOSE_DATE, changed[0].Last_Billed_Date__c);
    }

    @isTest
    static void backdatedWinLeavesAccountUnchanged() {
        Assert.isNull(classifyOne(CLOSE_DATE, CLOSE_DATE.addMonths(-1)));
        Assert.isNull(classifyOne(CLOSE_DATE, CLOSE_DATE));
    }

    @isTest
    static void severalWinsInOneSaveApplyOldestFirst() {
        Account acc = new Account(Id = fakeAccountId());
        // Passed newest first; the older win must be applied first
        List<Account> changed = AccountBusinessTypeHandler.classify(
            new List<Opportunity>{
                new Opportunity(AccountId = acc.Id, CloseDate = CLOSE_DATE),
                new Opportunity(AccountId = acc.Id, CloseDate = CLOSE_DATE.addMonths(-12))
            },
            new Map<Id, Account>{ acc.Id => acc });

        Assert.areEqual(1, changed.size());
        Assert.areEqual(AccountBusinessTypeHandler.EXISTING, changed[0].Business_Type__c);
        Assert.areEqual(CLOSE_DATE, changed[0].Last_Billed_Date__c);
    }

    @isTest
    static void movingDealToWonStageUpdatesAccount() {
        Account acct = new Account(Name = 'Business Type Test Account');
        insert acct;
        Contact testCon = new Contact(LastName = 'TestContact');
        insert testCon;
        Opportunity opp = new Opportunity(
            Name                   = 'Business Type Test Deal',
            AccountId              = acct.Id,
            Contact__c             = testCon.Id,
            Expected_Start_Date__c = Date.today().addDays(1),
            End_Date__c            = Date.today().addDays(2),
            CSDM_Lead__c           = 'Lishika',
            Amount                 = 1000,
            StageName              = 'Needs Analysis',
            CloseDate              = Date.today(),
            Pipeline__c            = 'Deal Pipeline',
            Product__c             = 'Techademy',
            Solution_Manager__c    = 'Sree Priyanka',
            Technical_Architect__c = 'Sameer',
            Delivery_CSM__c        = 'Aathif Fahad K',
            Mode__c                = 'Platform Only',
            PO_Status__c           = 'Pending',
            Line_of_Business__c    = 'Techademy: LMS Only'
        );
        insert opp;

        Test.startTest();
        opp.StageName = 'Invoiced';
        update opp;
        Test.stopTest();

        Account result = [SELECT Business_Type__c, Last_Billed_Date__c FROM Account WHERE Id = :acct.Id];
        Assert.areEqual(AccountBusinessTypeHandler.NEW_BUSINESS, result.Business_Type__c);
        Assert.areEqual(Date.today(), result.Last_Billed_Date__c);
    }
}
