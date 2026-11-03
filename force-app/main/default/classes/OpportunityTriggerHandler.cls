public class OpportunityTriggerHandler {
    public static void handleAfterUpdate(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        Set<String> parentIdStrs = new Set<String>();

        for (Opportunity newOpp : newOpps) {
            Opportunity oldOpp = oldMap.get(newOpp.Id);
            if (newOpp.Parent_Deal__c != oldOpp.Parent_Deal__c) {
                if (newOpp.Parent_Deal__c != null) parentIdStrs.add(newOpp.Parent_Deal__c);
                if (oldOpp.Parent_Deal__c != null) parentIdStrs.add(oldOpp.Parent_Deal__c);
            }
        }

        if (!parentIdStrs.isEmpty()) {
            recomputeParentDealAmounts(parentIdStrs);
        }
    }

    // Runs after the full transaction (including Flows) to ensure correct final values
    @future
    public static void recomputeParentDealAmounts(Set<String> parentIdStrs) {
        Set<Id> parentIds = new Set<Id>();
        for (String s : parentIdStrs) parentIds.add((Id) s);

        Map<Id, Parent_Deal__c> parentsToUpdate = new Map<Id, Parent_Deal__c>();
        for (Id pId : parentIds) {
            parentsToUpdate.put(pId, new Parent_Deal__c(
                Id = pId,
                Closed_Amount__c = 0,
                Commit_Amount__c = 0,
                Best_Case_Amount__c = 0,
                Pipeline_Amount__c = 0
            ));
        }

        for (AggregateResult r : [
            SELECT Parent_Deal__c parentId, ForecastCategoryName fc, SUM(Amount) total
            FROM Opportunity
            WHERE Parent_Deal__c IN :parentIds
            GROUP BY Parent_Deal__c, ForecastCategoryName
        ]) {
            Id pId = (Id) r.get('parentId');
            String fc = (String) r.get('fc');
            Decimal total = (Decimal) r.get('total');
            if (total == null) total = 0;
            Parent_Deal__c p = parentsToUpdate.get(pId);
            if (p == null) continue;
            if (fc == 'Closed')         p.Closed_Amount__c = total;
            else if (fc == 'Commit')    p.Commit_Amount__c = total;
            else if (fc == 'Best Case') p.Best_Case_Amount__c = total;
            else if (fc == 'Pipeline')  p.Pipeline_Amount__c = total;
        }

        update parentsToUpdate.values();
    }
}