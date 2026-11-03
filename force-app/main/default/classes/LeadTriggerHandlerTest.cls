@isTest
public class LeadTriggerHandlerTest {
	@isTest
    public static void testassignLeadsToAM(){
        Account accRec = new Account();
        accRec.Name = 'Test Account from Test Class';
        insert accRec;
        
        List<Lead> leadList = new List<Lead>();
        
        Lead ld1 = new Lead();
        ld1.AccountId__c = accRec.Id;
        ld1.LastName ='Test Ld 1';
        ld1.Company = 'Test Company';
        leadList.add(ld1);
        
        Lead ld2 = new Lead();
        ld2.AccountId__c = accRec.Id;
        ld2.LastName ='Test Ld 2';
        ld2.Company = 'Test Company';
        leadList.add(ld2);
        
        Lead ld3 = new Lead();
        ld3.AccountId__c = accRec.Id;
        ld3.LastName ='Test Ld 3';
        ld3.Company = 'Test Company';
        leadList.add(ld3);
        
        insert leadList;
        
        LeadTriggerHandler.assignLeadsToAM(leadList);
    }
}