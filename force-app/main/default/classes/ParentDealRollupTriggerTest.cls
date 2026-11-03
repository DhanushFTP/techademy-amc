@isTest(SeeAllData=true)
private class ParentDealRollupTriggerTest {

    private static Id getAccountId() {
        return [SELECT Id FROM Account WHERE Name = 'IIHT' LIMIT 1].Id;
    }

    private static List<Parent_Deal__c> createTwoParents(Id accId) {
        List<Parent_Deal__c> parents = new List<Parent_Deal__c>{
            new Parent_Deal__c(Name = 'PDRT Test 1 ' + System.currentTimeMillis(),
                Parent_Deal_Type__c = 'Strategic', Account__c = accId,
                Closed_Amount__c = 0, Commit_Amount__c = 0, Best_Case_Amount__c = 0, Pipeline_Amount__c = 0),
            new Parent_Deal__c(Name = 'PDRT Test 2 ' + System.currentTimeMillis(),
                Parent_Deal_Type__c = 'Strategic', Account__c = accId,
                Closed_Amount__c = 0, Commit_Amount__c = 0, Best_Case_Amount__c = 0, Pipeline_Amount__c = 0)
        };
        insert parents;
        return parents;
    }

    @isTest
    static void testMoveOppBetweenParents() {
        Id accId = getAccountId();
        List<Parent_Deal__c> parents = createTwoParents(accId);
        Id p1Id = parents[0].Id;
        Id p2Id = parents[1].Id;

        Opportunity opp = new Opportunity(Name = 'PDRT Opp 1', Amount = 10000, StageName = 'Closed Won',
            CloseDate = System.today(), Expected_Start_Date__c = System.today(), End_Date__c = System.today().addMonths(3),
            AccountId = accId, Parent_Deal__c = p1Id, ForecastCategoryName = 'Closed');
        insert opp;

        Test.startTest();
        opp.Parent_Deal__c = p2Id;
        update opp;
        Test.stopTest(); // forces @future to complete

        Parent_Deal__c p1 = [SELECT Closed_Amount__c FROM Parent_Deal__c WHERE Id = :p1Id];
        Parent_Deal__c p2 = [SELECT Closed_Amount__c FROM Parent_Deal__c WHERE Id = :p2Id];
        System.assertEquals(0, p1.Closed_Amount__c, 'Old parent should be decremented');
        System.assertEquals(10000, p2.Closed_Amount__c, 'New parent should be incremented');
    }

    @isTest
    static void testMoveOppAndChangeAmount() {
        Id accId = getAccountId();
        List<Parent_Deal__c> parents = createTwoParents(accId);
        Id p1Id = parents[0].Id;
        Id p2Id = parents[1].Id;

        Opportunity opp = new Opportunity(Name = 'PDRT Opp 2', Amount = 10000, StageName = 'Prospecting',
            CloseDate = System.today(), Expected_Start_Date__c = System.today(), End_Date__c = System.today().addMonths(3),
            AccountId = accId, Parent_Deal__c = p1Id, ForecastCategoryName = 'Pipeline');
        insert opp;

        Test.startTest();
        opp.Parent_Deal__c = p2Id;
        opp.Amount = 15000;
        update opp;
        Test.stopTest();

        Parent_Deal__c p1 = [SELECT Pipeline_Amount__c FROM Parent_Deal__c WHERE Id = :p1Id];
        Parent_Deal__c p2 = [SELECT Pipeline_Amount__c FROM Parent_Deal__c WHERE Id = :p2Id];
        System.assertEquals(0, p1.Pipeline_Amount__c, 'Old parent should be decremented');
        System.assertEquals(15000, p2.Pipeline_Amount__c, 'New parent gets new amount');
    }

    @isTest
    static void testMoveOppAndChangeCategory() {
        Id accId = getAccountId();
        List<Parent_Deal__c> parents = createTwoParents(accId);
        Id p1Id = parents[0].Id;
        Id p2Id = parents[1].Id;

        Opportunity opp = new Opportunity(Name = 'PDRT Opp 3', Amount = 10000, StageName = 'Closed Won',
            CloseDate = System.today(), Expected_Start_Date__c = System.today(), End_Date__c = System.today().addMonths(3),
            AccountId = accId, Parent_Deal__c = p1Id, ForecastCategoryName = 'Closed');
        insert opp;

        Test.startTest();
        opp.Parent_Deal__c = p2Id;
        opp.ForecastCategoryName = 'Commit';
        update opp;
        Test.stopTest();

        Parent_Deal__c p1 = [SELECT Closed_Amount__c FROM Parent_Deal__c WHERE Id = :p1Id];
        Parent_Deal__c p2 = [SELECT Commit_Amount__c FROM Parent_Deal__c WHERE Id = :p2Id];
        System.assertEquals(0, p1.Closed_Amount__c, 'Old parent Closed bucket should be 0');
        System.assertEquals(10000, p2.Commit_Amount__c, 'New parent Commit bucket incremented');
    }
}