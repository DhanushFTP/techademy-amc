public class DealErrorApprovalLogHelper {
    public static void processApprovalUpdates(List<Deal_Error_Approval_Log__c> newLogs, Map<Id, Deal_Error_Approval_Log__c> oldLogs) {
        List<Opportunity> opportunitiesToUpdate = new List<Opportunity>();
        
        // Fetch related Opportunities
        Set<Id> opportunityIds = new Set<Id>();
        for (Deal_Error_Approval_Log__c log : newLogs) {
            if (log.Deal__c != null) {
                opportunityIds.add(log.Deal__c);
            }
        }
        
        Map<Id, Opportunity> opportunityMap = new Map<Id, Opportunity>(
            [SELECT Id, Amount, CloseDate FROM Opportunity WHERE Id IN :opportunityIds]
        );
        
        for (Deal_Error_Approval_Log__c log : newLogs) {
            Deal_Error_Approval_Log__c oldLog = oldLogs.get(log.Id);
            
            // Check if Approval_Status__c changed to 'Approved'
            if (log.Approval_Status__c == 'Approved' && oldLog.Approval_Status__c != 'Approved') {
                Opportunity relatedOpp = opportunityMap.get(log.Deal__c);
                if (relatedOpp != null) {
                    Boolean needsUpdate = false;
                    
                    // Update Opportunity Amount if changed
                    if (relatedOpp.Amount != log.New_Amount__c && log.New_Amount__c != log.Old_Amount__c) {
                        relatedOpp.Amount = log.New_Amount__c;
                        needsUpdate = true;
                    }
                    
                    // Update Opportunity Close Date if changed
                    if (relatedOpp.CloseDate != log.New_CloseDate__c && log.New_CloseDate__c != log.Old_CloseDate__c) {
                        relatedOpp.CloseDate = log.New_CloseDate__c;
                        needsUpdate = true;
                    }
                    
                    if (needsUpdate) {
                        opportunitiesToUpdate.add(relatedOpp);
                    }
                }
            }
        }
        
        if (!opportunitiesToUpdate.isEmpty()) {
            update opportunitiesToUpdate;
        }
    }
}