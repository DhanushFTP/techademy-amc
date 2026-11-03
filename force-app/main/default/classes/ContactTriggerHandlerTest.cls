@IsTest
public class ContactTriggerHandlerTest {
    @isTest
    static void testAssignContactsToAM() {
        Account testAccount = new Account(Name = 'Test Account');
        insert testAccount;
        
        List<Contact> testContacts = new List<Contact>{
            new Contact(FirstName = 'John', LastName = 'Doe', AccountId = testAccount.Id),
                new Contact(FirstName = 'Jane', LastName = 'Doe', AccountId = testAccount.Id)
                };
                    insert testContacts;
        
        
    }
      @isTest
    static void testAddJtToTitleAndTitleToJt() {
        // Create test data
        List<Contact> testContacts = new List<Contact>{
            new Contact(FirstName = 'John', LastName = 'Doe', Title = 'Manager', Job_Title__c = null)
           
        };
        insert testContacts;

        
      
    }
      @isTest
    static void testAddJtToTitleAndTitleTo() {
        // Create test data
        List<Contact> testContacts = new List<Contact>{
            new Contact(FirstName = 'Jane', LastName = 'Doe', Title = null, Job_Title__c = 'Developer')
        };
        insert testContacts;

        
      
    }
    
}