trigger sendEmailTrigger on Email_Notification__e (after insert) {
    List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
    List<Deal_Error_Approval_Log__c> newErrorRecords = new List<Deal_Error_Approval_Log__c>();
    Map<Id, Deal_Error_Approval_Log__c> insertedLogs = new Map<Id, Deal_Error_Approval_Log__c>();
    
    for (Email_Notification__e eventRecord : Trigger.new) {
        Deal_Error_Approval_Log__c newEntry = new Deal_Error_Approval_Log__c(
            User_Name__c = eventRecord.User_Name__c,
            Deal__c = eventRecord.Deal_Id__c,
            Message__c = eventRecord.Message__c,
            Log_Type__c = 'Error',
            Old_CloseDate__c = eventRecord.Old_CloseDate__c,
            New_CloseDate__c = eventRecord.New_CloseDate__c,
            Old_Amount__c = eventRecord.Old_Amount__c,
            New_Amount__c = eventRecord.New_Amount__c,
            Reason_for_Change__c = eventRecord.Reason_for_Change__c
        );
        newErrorRecords.add(newEntry);
    }
    
    if (!newErrorRecords.isEmpty()) {
        insert newErrorRecords;
        for (Deal_Error_Approval_Log__c log : newErrorRecords) {
            insertedLogs.put(log.Deal__c, log);
        }
    }
    String orgWideEmailAddressId = System.Label.OrgWideEmailAddressID;
    OrgWideEmailAddress[] orgWideEmails = [SELECT Id FROM OrgWideEmailAddress WHERE Address =: orgWideEmailAddressId LIMIT 1];
    
    for (Email_Notification__e eventRecord : Trigger.new) {
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        
        if (!orgWideEmails.isEmpty()) {
            email.setOrgWideEmailAddressId(orgWideEmails[0].Id);
        }
        
        // List<String> recipients = new List<String>();
        // String[] emailAddresses = eventRecord.Recipient__c.split(';');
        // for (String emailAddress : emailAddresses) {
        //     recipients.add(emailAddress.trim());
        // }
        
        // email.setToAddresses(recipients);
        email.setToAddresses(new List<String>{eventRecord.Recipient__c});
        email.setSubject(eventRecord.Subject__c);
        
        if (insertedLogs.containsKey(eventRecord.Deal_Id__c)) {
            String recordId = insertedLogs.get(eventRecord.Deal_Id__c).Id;
            String updatedBody = eventRecord.Body__c.replace('NEW_RECORD_ID', recordId);
            email.setHtmlBody(updatedBody);
        } else {
            email.setHtmlBody(eventRecord.Body__c);
        }
        
        emails.add(email);
    }
    
    if (!emails.isEmpty()) {
        Messaging.sendEmail(emails);
    }
}