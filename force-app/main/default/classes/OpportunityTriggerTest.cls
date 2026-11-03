@isTest
public class OpportunityTriggerTest {

    @isTest
    static void testBeforeInsert() {
        // Create required parent records
        Account acct = new Account(Name = 'Test Account');
        insert acct;
        Contact testCon = new Contact(LastName = 'TestContact');
        insert testCon;

        // Prepare Opportunities with all required fields
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 5; i++) {
            opps.add(new Opportunity(
                Name                   = 'Test Opp ' + i,
                AccountId              = acct.Id,
                Contact__c             = testCon.Id,
                Expected_Start_Date__c = Date.today().addDays(1),
                End_Date__c            = Date.today().addDays(2),
                CSDM_Lead__c           = 'Lishika',
                Amount                 = 1000 * (i + 1),
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
            ));
        }

        Test.startTest();
            insert opps;
        Test.stopTest();

        // Verify trigger logic ran (Amount_In_Words__c was populated)
        for (Opportunity opp : [SELECT Amount_In_Words__c FROM Opportunity WHERE Id IN :opps]) {
            System.assertNotEquals(
                null,
                opp.Amount_In_Words__c,
                'Amount in Words should not be null'
            );
        }
    }

    @isTest
    static void testBeforeUpdate() {
        // Create required parent records
        Account acct = new Account(Name = 'Test Account');
        insert acct;
        Contact testCon = new Contact(LastName = 'TestContact');
        insert testCon;

        // Prepare and insert Opportunities with all required fields
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 5; i++) {
            opps.add(new Opportunity(
                Name                   = 'Test Opp ' + i,
                AccountId              = acct.Id,
                Contact__c             = testCon.Id,
                Expected_Start_Date__c = Date.today().addDays(1),
                End_Date__c            = Date.today().addDays(2),
                CSDM_Lead__c           = 'Lishika',
                Amount                 = 1000 * (i + 1),
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
            ));
        }
        insert opps;

        // Change a field to fire the update trigger
        for (Opportunity opp : opps) {
            opp.Amount = 2000;
        }

        Test.startTest();
            update opps;
        Test.stopTest();

        // Verify trigger logic ran (Amount_In_Words__c was updated)
        for (Opportunity opp : [SELECT Amount_In_Words__c FROM Opportunity WHERE Id IN :opps]) {
            System.assertNotEquals(
                null,
                opp.Amount_In_Words__c,
                'Amount in Words should not be null'
            );
        }
    }
}