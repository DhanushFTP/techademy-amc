@isTest
public class DealErrorApprovalLogHelperTest {
    @testSetup
    static void setupTestData() {
        // Create test Opportunities
        Account newAccount = new Account(Name = 'New Account');
        insert newAccount;

        Contact  newContact = new Contact(LastName = 'New Contact', AccountId = newAccount.Id);
        insert newContact;
        Opportunity opp1 = new Opportunity(
                Name = 'Test Opportunity',
                StageName = 'Closed Won',
                CloseDate = Date.today().addDays(10),
                Amount = 10000,
                Contact__c = newContact.Id,
                Expected_Start_Date__c = Date.today().addDays(4), 
                End_Date__c = Date.today().addDays(10), 
                Technical_Architect__c = 'Aditya', 
                
                Product__c             = 'Techademy',
                Solution_Manager__c    = 'Neha',
                CSDM_Lead__c           = 'Lishika',
                Delivery_CSM__c        = 'Soma',
                Mode__c                = 'Platform Only',
                PO_Status__c           = 'Pending',
                Line_of_Business__c    = 'Techademy: LMS Only'
        );
        Opportunity opp2 = new Opportunity(
                Name = 'Test Opportunity 2',
                StageName = 'Closed Won',
                CloseDate = Date.today().addDays(10),
                Amount = 20000,
                Contact__c = newContact.Id,
                Expected_Start_Date__c = Date.today().addDays(4), 
                End_Date__c = Date.today().addDays(10), 
                Technical_Architect__c = 'Aditya', 
                Product__c             = 'Techademy',
                Solution_Manager__c    = 'Neha',
                CSDM_Lead__c           = 'Lishika',
                Delivery_CSM__c        = 'Soma',
                Mode__c                = 'Platform Only',
                PO_Status__c           = 'Pending',
                Line_of_Business__c    = 'Techademy: LMS Only'
        );
        insert new List<Opportunity>{opp1, opp2};
        
        // Create initial Deal_Error_Approval_Log__c records
        Deal_Error_Approval_Log__c log1 = new Deal_Error_Approval_Log__c(
            Deal__c = opp1.Id,
            New_Amount__c = 60000,
            Reason_for_Change__c = 'test',
            New_CloseDate__c = Date.today().addDays(10)
        );
        
        Deal_Error_Approval_Log__c log2 = new Deal_Error_Approval_Log__c(
            Deal__c = opp2.Id,
            New_Amount__c = 85000,
            Reason_for_Change__c = 'test',
            New_CloseDate__c = Date.today().addDays(40)
        );
        
        insert new List<Deal_Error_Approval_Log__c>{log1, log2};
    }
    
    @isTest
    static void testProcessApprovalUpdates() {
        // Fetch test data
        List<Deal_Error_Approval_Log__c> logs = [SELECT Id, Deal__c, Approval_Status__c, Reason_for_Change__c, New_Amount__c, New_CloseDate__c FROM Deal_Error_Approval_Log__c];
        Map<Id, Deal_Error_Approval_Log__c> oldLogs = new Map<Id, Deal_Error_Approval_Log__c>();
        
        for (Deal_Error_Approval_Log__c log : logs) {
            oldLogs.put(log.Id, log);
        }
        
        // Update logs to simulate approval
        for (Deal_Error_Approval_Log__c log : logs) {
            log.Approval_Status__c = 'Approved';
        }
        
        update logs;
        
        Test.startTest();
        DealErrorApprovalLogHelper.processApprovalUpdates(logs, oldLogs);
        Test.stopTest();
    }
}