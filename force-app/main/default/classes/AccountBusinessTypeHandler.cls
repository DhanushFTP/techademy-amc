/***************************************************************
 *  Class Name   : AccountBusinessTypeHandler
 *  Company      : Fingertipplus
 *  Author       : Dhanush
 *  Used By      : OpportunityTrigger (after insert, after update)
 *  Description  : Classifies an Account as New Business or Existing when one of its deals is won.
 *                 - A deal is won when it moves into a Won stage (OpportunityAlertEmailHandler.STAGES_WON).
 *                 - Last Billed Date blank, or 24 months or more before the deal's Close Date -> New Business.
 *                 - Otherwise (billed within the last 24 months) -> Existing.
 *                 - Last Billed Date is then set to the deal's Close Date.
 *                 - A win whose Close Date is not after the current Last Billed Date (backdated deal,
 *                   or the trigger re-firing in the same transaction) leaves the account unchanged.
 *                 - Runs without sharing: the deal owner may not have edit access to the Account.
 ***************************************************************/
public without sharing class AccountBusinessTypeHandler {

    public static final String NEW_BUSINESS = 'New Business';
    public static final String EXISTING = 'Existing';
    private static final Integer GAP_MONTHS = 24;

    /**
     * @description Finds deals that just moved into a Won stage and updates their accounts.
     * @param newOpps Trigger.new
     * @param oldMap  Trigger.oldMap (null on insert)
     */
    public static void handleAfterSave(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        List<Opportunity> wonOpps = new List<Opportunity>();
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : newOpps) {
            Boolean wasWon = oldMap != null
                && OpportunityAlertEmailHandler.STAGES_WON.contains(oldMap.get(opp.Id).StageName);
            if (!wasWon && opp.AccountId != null && opp.CloseDate != null
                    && OpportunityAlertEmailHandler.STAGES_WON.contains(opp.StageName)) {
                wonOpps.add(opp);
                accountIds.add(opp.AccountId);
            }
        }
        if (wonOpps.isEmpty()) {
            return;
        }

        Map<Id, Account> accounts = new Map<Id, Account>(
            [SELECT Id, Last_Billed_Date__c, Business_Type__c FROM Account WHERE Id IN :accountIds]);
        List<Account> changed = classify(wonOpps, accounts);
        if (!changed.isEmpty()) {
            update changed;
        }
    }

    /**
     * @description Applies the won deals to their accounts, oldest Close Date first, so several
     *              wins on one account in the same save are classified in order.
     * @return The accounts whose Business Type / Last Billed Date changed.
     */
    @TestVisible
    private static List<Account> classify(List<Opportunity> wonOpps, Map<Id, Account> accounts) {
        List<Opportunity> sorted = wonOpps.clone();
        sorted.sort(new CloseDateAscending());

        Map<Id, Account> changed = new Map<Id, Account>();
        for (Opportunity opp : sorted) {
            Account acc = accounts.get(opp.AccountId);
            Date lastBilled = acc.Last_Billed_Date__c;
            if (lastBilled != null && opp.CloseDate <= lastBilled) {
                continue;
            }
            acc.Business_Type__c = (lastBilled == null || lastBilled.addMonths(GAP_MONTHS) <= opp.CloseDate)
                ? NEW_BUSINESS : EXISTING;
            acc.Last_Billed_Date__c = opp.CloseDate;
            changed.put(acc.Id, acc);
        }
        return changed.values();
    }

    private class CloseDateAscending implements Comparator<Opportunity> {
        public Integer compare(Opportunity a, Opportunity b) {
            return b.CloseDate.daysBetween(a.CloseDate);
        }
    }
}
