public class TrainerSolutionRequestEmailHelper {
    public static void processTrainerSolutionRequests(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppMap) {
        if(newOpps == null || newOpps.isEmpty()) return;
        
        // Get org base URL from a custom label
        String orgUrl = System.Label.OrgUrl;
        
        // Hardcoded mapping of Solution Manager names to their email addresses
        // (Make sure these keys match the values stored in Solution_Manager_Email__c)
        Map<String, String> managerEmailMapping = new Map<String, String>{
            'Sree Priyanka' => 'Priyanka.Sree@techademy.com',
            'Samreen' => 'Samreen.p@techademy.com',
            'Chandan' => 'chandan.s@techademy.com',
            'Pushpa' => 'pushpa@techademy.com',
            'Rashmita' => 'rashmita.das@techademy.com',
            'Dharini' => 'Dharini.M@techademy.com',
            'Ilamthi' => 'ilamathi.m@techademy.com',
            'Neha' => 'neha.rathi@techademy.com',
            'Koushik' => 'vittalpur.kowshik@techademy.com',
            'Manokaran' => 'Priyanka.Sree@techademy.com',
            'Harisha' => 'Harisha.b@techademy.com',
            'Yadhu' => 'Priyanka.Sree@techademy.com',
            'Shalini' => 'shalini.m@techademy.com',
            'Pratyusha' => 'p.prathyusha@techademy.com',
            'Medha' => 'medha.singh@techademy.com',
            'Vismitha' => 'Priyanka.Sree@techademy.com',
            'Khushboo' => 'khushboo.singh@techademy.com',
            'Raj' => 'raj@techademy.com',
            'Karthik Kumar' => 'karthik.kumar@techademy.com',
            'Felix' => 'felix.raj@techademy.com'

        };
        
        // Get the current user's name (if needed for the email)
        User currentUser = [SELECT Id, Name FROM User WHERE Id = :UserInfo.getUserId()];
        
        List<Email_Notification__e> events = new List<Email_Notification__e>();
        
        for(Opportunity opp : newOpps) {
            Boolean shouldSend = false;
            
            // For update events, check if the Solution Manager field was changed with stage Solution Pending
            if(oldOppMap != null) {
                Opportunity oldOpp = oldOppMap.get(opp.Id);
                if(oldOpp != null 
                && opp.Solution_Manager__c != oldOpp.Solution_Manager__c 
                && opp.StageName == 'Solution Pending') {
                    shouldSend = true;
                }
            }
            // For insert events, check if the Solution Manager is not 'Not Applicable' and stage is Solution Pending
            else {
                if(opp.Solution_Manager__c != 'Not Applicable'
                && opp.StageName == 'Solution Pending') {
                    shouldSend = true;
                }
            }
            
            if(shouldSend) {
                // Read the value from Solution_Manager_Email__c and map to the hardcoded recipient email
                String managerKey = opp.Solution_Manager__c;
                if(String.isNotBlank(managerKey) && managerEmailMapping.containsKey(managerKey)) {
                    String recipientEmail = managerEmailMapping.get(managerKey);
                    
                    // Build the email body using the provided template
                    String emailBody = 
                        'Hi,\n\n' +
                        'A new trainer solution request has been raised:\n' +
                        'Deal Name: ' + opp.Name + '\n' +
                       // 'Solution Requested at: ' + String.valueOf(opp.Solution_Requested_Date__c) + '\n' +
                        'Skills for Training: \n' +
                        (opp.Skills_for_Training__c != null ? opp.Skills_for_Training__c + '\n' : '') +
                       // (opp.Skills__c != null ? opp.Skills__c + '\n' : '') +
                       // 'Training City: \n' +
                      //  (opp.Training_City__c != null ? opp.Training_City__c + '\n' : '') +
           
                        'Click here to access the deal:\n' + 
                        orgUrl + '/' + opp.Id;
                    
                    // Build the email subject
                    String emailSubject = 'New Trainer Solution Request for Deal: ' + opp.Name;
                    
                    // Publish the platform event for sending email
                    events.add(new Email_Notification__e(
                        Recipient__c = recipientEmail,
                        Subject__c = emailSubject,
                        Body__c = emailBody,
                        Deal_Id__c = opp.Id,
                        User_Name__c = currentUser.Name,
                        Message__c = 'A new trainer solution request has been raised.'
                    ));
                }
            }
        }
        
        if(!events.isEmpty()){
            EventBus.publish(events);
        }
    }
}