/***************************************************************
 *  Class Name   : AccountBusinessTypeHandler
 *  Company      : Fingertipplus
 *  Author       : Dhanush
 *  Used By      : OpportunityTrigger (after insert, after update)
 *  Description  : Classifies an Account as New Business or Existing when one of its deals is won.
 *                 - A deal is won when it moves into a Won stage (OpportunityAlertEmailHandler.STAGES_WON).
 *                 - Financial year runs April to March (same as the Forecast page).
 *                 - Last billed in one of the 2 financial years before the deal's FY -> Existing.
 *                 - Never billed, or last billed 3+ financial years before -> New Business.
 *                 - Last billed earlier in the same FY -> Business Type kept as is
 *                   (a new customer stays New Business for the rest of that FY).
 *                 - Last Billed Date is then set to the deal's Close Date.
 *                 - A win whose Close Date is not after the current Last Billed Date (backdated deal,
 *                   or the trigger re-firing in the same transaction) leaves the account unchanged.
 *                 - Runs without sharing: the deal owner may not have edit access to the Account.
 ***************************************************************/
public without sharing class AccountBusinessTypeHandler {

    public static final String NEW_BUSINESS = 'New Business';
    public static final String EXISTING = 'Existing';
    private static final Integer PRIOR_FYS = 2;

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
            Integer fyGap = lastBilled == null ? null : fiscalYear(opp.CloseDate) - fiscalYear(lastBilled);
            if (fyGap == null || fyGap > PRIOR_FYS) {
                acc.Business_Type__c = NEW_BUSINESS;
            } else if (fyGap > 0) {
                acc.Business_Type__c = EXISTING;
            }
            acc.Last_Billed_Date__c = opp.CloseDate;
            changed.put(acc.Id, acc);
        }
        return changed.values();
    }

    /** Start year of the April-March financial year: 10 Feb 2026 -> 2025 (FY 2025-26). */
    private static Integer fiscalYear(Date d) {
        return d.month() >= 4 ? d.year() : d.year() - 1;
    }

    private class CloseDateAscending implements Comparator<Opportunity> {
        public Integer compare(Opportunity a, Opportunity b) {
            return b.CloseDate.daysBetween(a.CloseDate);
        }
    }
}