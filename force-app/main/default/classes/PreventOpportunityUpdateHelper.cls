public class PreventOpportunityUpdateHelper {
  // Test hook: If set, this value is used instead of Date.today()
    public static Date todayOverride;

    public static void validateAmountUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppMap) {
        if (oldOppMap == null) return;
        
        // Use the override date if available (and we're running tests); otherwise use Date.today()
        Date today = (Test.isRunningTest() && todayOverride != null) ? todayOverride : Date.today();

        
        // Collect email notification events to be published
        List<Email_Notification__e> events = new List<Email_Notification__e>();

        // Get org base URL from custom label
        String orgUrl = System.Label.OrgUrl;

        // Get the current user's profile and role details
        User currentUser = [SELECT Id, Name, UserRole.Name, ProfileId, ManagerId FROM User WHERE Id = :UserInfo.getUserId()];
        Profile userProfile = [SELECT Name FROM Profile WHERE Id = :currentUser.ProfileId LIMIT 1];

        String userProfileName = userProfile.Name;
        String userName = currentUser.Name;

        // Define restricted profiles and forecast categories
        Set<String> restrictedProfiles = new Set<String>{'Account Manager', 'System Administrator'};
        Set<String> restrictedForecasts = new Set<String>{'Commit', 'Best Case'};

        // Define static email recipients
        List<String> notificationEmails = new List<String>{'karthik.kumar@techademy.com', 'manjunath.rao@techademy.com'};

        // Fetch email template
        EmailTemplate emailTemplate = [
            SELECT HtmlValue 
            FROM EmailTemplate 
            WHERE DeveloperName = 'Prevent_Opportunity_Update_Email_Template' 
            LIMIT 1
        ];

        for (Opportunity opp : newOpps) {
            if (oldOppMap.containsKey(opp.Id)) {
                Opportunity oldOpp = oldOppMap.get(opp.Id);
                

                // Get today's date
                //Date today = Date.today();

                // Define last 15 days of the current month as restricted period
                Date lastDayOfMonth = today.toStartOfMonth().addMonths(1).addDays(-1);
                Date startOfRestrictedWindow = lastDayOfMonth.addDays(-14);
                Boolean isRestrictedPeriod = today >= startOfRestrictedWindow && today <= lastDayOfMonth;
                
                System.debug('▶ today                   = ' + today);
                System.debug('▶ lastDayOfMonth          = ' + lastDayOfMonth);
                System.debug('▶ startOfRestrictedWindow = ' + startOfRestrictedWindow);
                System.debug('▶ isRestrictedPeriod      = ' + isRestrictedPeriod);
                
                // Validate forecast category
                Boolean isForecastRestricted = restrictedForecasts.contains(opp.ForecastCategoryName);

                // Check if amount decreased by more than 20%
                Boolean isAmountDecreasedBy20 = (oldOpp.Amount != null && opp.Amount != null && opp.Amount < (oldOpp.Amount * 0.8));

                // Check if the month of close date changed
                Boolean isCloseDateMonthChanged =
                    (oldOpp.CloseDate.month() == today.month()) &&
                    (opp.CloseDate.month()    != today.month());
                
                // Combine all restriction checks
               Boolean isUpdateRestricted = isForecastRestricted && isRestrictedPeriod &&
                                            (isAmountDecreasedBy20 || isCloseDateMonthChanged);
                       


                if (restrictedProfiles.contains(userProfileName) && isUpdateRestricted) {
                    String errorMessage = 'Opportunity update not allowed';

                    // Get user-entered reason
                    String reasonForChange = opp.Reason_for_Change__c;

                    // Build the email body from template
                    String htmlBody = emailTemplate.HtmlValue;
                    htmlBody = htmlBody.replace('{{{!Opportunity.Id}}}', opp.Id);
                    htmlBody = htmlBody.replace('{{{oldOpp.Amount}}}', String.valueOf(oldOpp.Amount));
                    htmlBody = htmlBody.replace('{{{opp.Amount}}}', String.valueOf(opp.Amount));
                    htmlBody = htmlBody.replace('{{{oldOpp.CloseDate}}}', String.valueOf(oldOpp.CloseDate));
                    htmlBody = htmlBody.replace('{{{opp.CloseDate}}}', String.valueOf(opp.CloseDate));
                    htmlBody = htmlBody.replace('{{{userName}}}', userName);
                    htmlBody = htmlBody.replace('{{{orgUrl}}}', orgUrl);
                    // htmlBody = htmlBody.replace('{{{reasonForChange}}}', reasonForChange);
                    htmlBody = htmlBody.replace('{{{reasonForChange}}}', reasonForChange != null ? reasonForChange : 'Reason not provided');


                    // Send event to all configured recipients
                    for (String email : notificationEmails) {
                        events.add(new Email_Notification__e(
                            Recipient__c = email,
                            Subject__c = '🚨 Unauthorized Opportunity Update Attempt',
                            Body__c = htmlBody,
                            User_Name__c = userName,
                            Deal_Id__c = opp.Id,
                            Message__c = 'User: ' + userName + ' (' + userProfileName + ') attempted a restricted change.',
                            Old_CloseDate__c = oldOpp.CloseDate,
                            New_CloseDate__c = opp.CloseDate,
                            Old_Amount__c = oldOpp.Amount,
                            New_Amount__c = opp.Amount,
                            Reason_for_Change__c = reasonForChange
                        ));
                    }

                    // Block the update
                    try {
                        opp.addError(errorMessage);
                    } catch (Exception e) {
                        System.debug('Error while adding restriction message: ' + e.getMessage());
                    }
                }
            }
        }

        // Publish platform events if any were created
        if (!events.isEmpty()) {
            EventBus.publish(events);
        }
    }
}