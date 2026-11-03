@isTest
private class PreventOpportunityUpdateHelperTest {

    @isTest
    static void testValidateAmountUpdate() {
    
     // Query the test user created in @testSetup
        UserRole keyAccountRole = new UserRole(Name = 'Key Accounts : Athul', DeveloperName = 'Key_Accounts_Athul_Test');
        insert keyAccountRole;
        
        // Create a User with Key Accounts Role
        User keyManagerUser = new User(
            FirstName = 'Manager',
            LastName = 'User',
            Email = 'testuser@example.com',
            Username = 'testuser' + System.currentTimeMillis() + '@test.com',
            Alias = 'muser',
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id,
            UserRoleId = keyAccountRole.Id,
            LanguageLocaleKey = 'en_US'
        );
        insert keyManagerUser;
        
        User keyAccountUser = new User(
            FirstName = 'Test',
            LastName = 'User',
            Email = 'testuser@example.com',
            Username = 'testuser' + System.currentTimeMillis() + '@test.com',
            Alias = 'tuser',
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1].Id,
            UserRoleId = keyAccountRole.Id,
            LanguageLocaleKey = 'en_US',
            ManagerId = keyManagerUser.Id
        );
        insert keyAccountUser;
        
    
    
        Test.startTest();
        
          // Run as Key Account User
        System.runAs(keyAccountUser) {

        // Create test Account and Contact
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        Contact con = new Contact(LastName = 'Test Contact', AccountId = acc.Id);
        insert con;

        // Set up a fixed date (if needed) so that today is inside the restricted window.
        // (Make sure this fixed date is set before calculating 'today')
         //Test.setFixedDate(Date.newInstance(2025, 3, 30));  // Uncomment if desired
         
         // Set a fixed date for testing by overriding the helper's "today" value.
        PreventOpportunityUpdateHelper.todayOverride = Date.newInstance(2025, 3, 30);


        // Calculate dates based on Date.today()
        Date today = Date.newInstance(2025, 3, 30);
        Date lastDay = today.toStartOfMonth().addMonths(1).addDays(-1);
        Date restrictedDate = lastDay.addDays(-5);

        // Create Opportunity with valid initial values
        Opportunity testopp = new Opportunity(
            Name = 'Restricted Test Opp',
            StageName = 'Campaign',
            CloseDate = restrictedDate,
            Amount = 100000,
            ForecastCategoryName = 'Commit', // meets restricted forecast criteria
            Contact__c = con.Id,
            Reason_for_Change__c = 'Initial setup for test',
            Expected_Start_Date__c = today.addDays(2),
            End_Date__c = today.addDays(10),
            Technical_Architect__c = 'Aditya',
            Solution_Manager__c = 'Not Applicable',
            Training_City__c = 'Mumbai',
            Product__c = 'Instructor_Led',
            Line_of_Business__c = 'ILT Freshers Training',
            CSDM_Lead__c = 'Lishika',
            Skill_Category__c = 'Web Tech - Java',
            Skills_for_Training__c = 'Java'
            //Mode__c = 'ILT Only'
        );
        insert testopp;

        // Retrieve the record for update simulation
        Opportunity updatedOpp = [SELECT Id, Amount, CloseDate, Name, StageName, ForecastCategoryName, Reason_for_Change__c, Solution_Manager__c, Training_City__c, Skills_for_Training__c 
                                   FROM Opportunity 
                                   WHERE Id = :testopp.Id 
                                   LIMIT 1];

        // Modify the fields to violate the restriction:
        // - Amount drop > 20% (100,000 -> 75,000)
        // - CloseDate's month is changed (add one month)
        // Solution Manager is updated
        updatedOpp.Amount = 75000;
        updatedOpp.CloseDate = updatedOpp.CloseDate.addMonths(1);
        updatedOpp.Reason_for_Change__c = 'Test reason for restriction';
        updatedOpp.StageName = 'Solution Pending';
        updatedOpp.Solution_Manager__c = 'Samreen';
        updatedOpp.Training_City__c = 'Mumbai';
       // updatedOpp.Skills__c = 'Java';

    // Mock Old Map
            Map<Id, Opportunity> oldOppMap = new Map<Id, Opportunity>{ testOpp.Id => testopp };

            
            PreventOpportunityUpdateHelper.validateAmountUpdate(new List<Opportunity>{ updatedOpp }, oldOppMap);
          TrainerSolutionRequestEmailHelper.processTrainerSolutionRequests(new List<Opportunity>{ updatedOpp }, oldOppMap);
            
       } 
    
        Test.stopTest();
    }
}