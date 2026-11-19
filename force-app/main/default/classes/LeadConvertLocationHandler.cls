/**
 * @description  When a lead is converted, copies its Lead Geo Location (captured on the phone) to the
 *               converted Account's Account Location, so the rep can check in on the account without
 *               capturing the location again.
 *
 *               The location is copied only when the Account has no Account Location yet. An existing
 *               Account Location is never changed here (it stays under the Override Location rule), so
 *               the Account_Location_Locked validation rule never blocks a conversion.
 *               When several converted leads go to the same Account, the first one with a location is used.
 *
 *               Check-ins stay on the converted lead; they are not moved to the Account.
 *
 *               Called from leadTrigger (after update). Bulk-safe: one query and one update for the
 *               whole batch. Updates run with allOrNone = false, so a failure never blocks the
 *               conversion; every copy (success or failure) is logged to lcon__Error_Message_Handler__c
 *               with Error Point 'Lead Convert Location'.
 *
 * @author       Tharun N
 * @date         06-11-2026
 * @group        Lead
 */
public without sharing class LeadConvertLocationHandler {

    private static final String LOG_POINT = 'Lead Convert Location';

    /**
     * @description Copies the lead location to the converted Account for leads converted in this save.
     * @param newLeads Trigger.new
     * @param oldMap   Trigger.oldMap
     */
    public static void copyLocationToAccount(List<Lead> newLeads, Map<Id, Lead> oldMap) {
        // Converted Account Id -> the lead whose location is copied
        Map<Id, Lead> leadByAccountId = new Map<Id, Lead>();
        for (Lead ld : newLeads) {
            Lead old = oldMap == null ? null : oldMap.get(ld.Id);
            Boolean justConverted = ld.IsConverted && (old == null || !old.IsConverted);
            if (justConverted
                    && ld.ConvertedAccountId != null
                    && ld.Lead_Geo_Location__Latitude__s != null
                    && ld.Lead_Geo_Location__Longitude__s != null
                    && !leadByAccountId.containsKey(ld.ConvertedAccountId)) {
                leadByAccountId.put(ld.ConvertedAccountId, ld);
            }
        }
        if (leadByAccountId.isEmpty()) {
            return;
        }

        List<Account> toUpdate = new List<Account>();
        for (Account acc : [
            SELECT Id, Account_Location__Latitude__s, Account_Location__Longitude__s
            FROM Account
            WHERE Id IN :leadByAccountId.keySet()
        ]) {
            if (acc.Account_Location__Latitude__s == null || acc.Account_Location__Longitude__s == null) {
                Lead ld = leadByAccountId.get(acc.Id);
                toUpdate.add(new Account(
                    Id                             = acc.Id,
                    Account_Location__Latitude__s  = ld.Lead_Geo_Location__Latitude__s,
                    Account_Location__Longitude__s = ld.Lead_Geo_Location__Longitude__s
                ));
            }
        }
        if (toUpdate.isEmpty()) {
            return;
        }

        List<Database.SaveResult> results = Database.update(toUpdate, false);
        writeLogs(toUpdate, results, leadByAccountId);
    }

    /**
     * @description One log row per copied location. Logging never blocks the conversion.
     */
    private static void writeLogs(List<Account> updated, List<Database.SaveResult> results,
                                  Map<Id, Lead> leadByAccountId) {
        try {
            List<lcon__Error_Message_Handler__c> logs = new List<lcon__Error_Message_Handler__c>();
            for (Integer i = 0; i < updated.size(); i++) {
                Account acc = updated[i];
                Database.SaveResult result = results[i];
                Lead ld = leadByAccountId.get(acc.Id);
                String message = 'Lead: ' + ld.Id
                    + ', Account: ' + acc.Id
                    + ', Location: ' + acc.Account_Location__Latitude__s + ', ' + acc.Account_Location__Longitude__s
                    + ', User: ' + UserInfo.getName()
                    + ', Status: ' + (result.isSuccess() ? 'Success' : 'Failed');
                if (!result.isSuccess() && !result.getErrors().isEmpty()) {
                    message += ', Error: ' + result.getErrors()[0].getMessage();
                }
                logs.add(new lcon__Error_Message_Handler__c(
                    lcon__Error_Message__c = message,
                    lcon__Error_Point__c   = LOG_POINT
                ));
            }
            Database.insert(logs, false);
        } catch (Exception ignored) {
            // Logging must never block the conversion
        }
    }
}