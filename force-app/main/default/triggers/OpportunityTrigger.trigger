trigger OpportunityTrigger on Opportunity (before insert, after insert, before update, after update) {
    // BEFORE context
    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            // If needed, add any before insert logic here.
        }
        if (Trigger.isUpdate) {
            // Call helper to update amount in words in before update
            opportunityTriggerHelper.updateAmountInWords(Trigger.new);
            // Validate and restrict update if needed
            if (System.Label.restrictOpportunityUpdate == 'true') {
                PreventOpportunityUpdateHelper.validateAmountUpdate(Trigger.new, Trigger.oldMap);
            }
        }
    }

    // AFTER context
    if (Trigger.isAfter) {
        if (Trigger.isInsert) {
            // Call helper to update amount in words in after insert if required
            opportunityTriggerHelper.updateAmountInWords(Trigger.new);
            // Process trainer solution requests for new records (no oldMap available)
            TrainerSolutionRequestEmailHelper.processTrainerSolutionRequests(Trigger.new, null);
            //Added @dhanush on 03/11/2026 classifies the account as New Business / Existing when a deal is created in a won stage
            AccountBusinessTypeHandler.handleAfterSave(Trigger.new, null);
        }
        if (Trigger.isUpdate) {
            // Process trainer solution requests for updated records (oldMap available)
            TrainerSolutionRequestEmailHelper.processTrainerSolutionRequests(Trigger.new, Trigger.oldMap);
            // Roll up amount to Parent_Deal__c on parent change
            OpportunityTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
            // Send deal alert emails on high value, Closed Won and Closed Lost deal changes
            // Author: Tharun N | Date: 28-09-2026
            OpportunityAlertEmailHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
            //Added @dhanush on 03/11/2026 classifies the account as New Business / Existing when a deal moves to a won stage
            AccountBusinessTypeHandler.handleAfterSave(Trigger.new, Trigger.oldMap);
        }
    }
}