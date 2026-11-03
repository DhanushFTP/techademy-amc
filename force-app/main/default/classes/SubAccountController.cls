public with sharing class SubAccountController {

    // ── Helper to throw AuraHandledException with message properly set ──
    private static void throwAuraError(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        throw e;
    }

    // ── Get parent account details for pre-filling the sub-account form ──
    // Also returns isOwner so the UI can gate the modal before calling createSubAccount
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getAccountDetails(Id accountId) {
        if (accountId == null) {
            throwAuraError('Account ID is required.');
        }

        List<Account> accs = [
            SELECT Id, Name, OwnerId, Website, Phone, Type,
                   Account_Location__Latitude__s, Account_Location__Longitude__s
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];

        if (accs.isEmpty()) {
            throwAuraError('Account not found or you do not have access to it.');
        }
        Account acc = accs[0];

        Map<String, Object> result = new Map<String, Object>();
        result.put('name',      acc.Name);
        result.put('website',   acc.Website);
        result.put('phone',     acc.Phone);
        result.put('type',      acc.Type);
        result.put('latitude',  acc.Account_Location__Latitude__s);
        result.put('longitude', acc.Account_Location__Longitude__s);
        result.put('isOwner',   acc.OwnerId == UserInfo.getUserId());
        return result;
    }

    // ── Create a sub-account under the given parent ──
    // Ownership is re-validated server-side regardless of the UI check
    @AuraEnabled
    public static Id createSubAccount(
        Id     parentId,
        String subAccountName,
        Decimal latitude,
        Decimal longitude,
        String website,
        String phone
    ) {
        if (String.isBlank(subAccountName)) {
            throwAuraError('Sub Account Name is required.');
        }

        if (parentId == null) {
            throwAuraError('Parent account is required.');
        }

        // Re-validate ownership server-side
        List<Account> parents = [
            SELECT OwnerId, Type
            FROM Account
            WHERE Id = :parentId
            LIMIT 1
        ];

        if (parents.isEmpty()) {
            throwAuraError('Parent account not found.');
        }
        Account parent = parents[0];

        if (parent.OwnerId != UserInfo.getUserId()) {
            throwAuraError('You must be the account owner to create a sub-account.');
        }

        Account subAcc = new Account(
            Name                            = subAccountName,
            ParentId                        = parentId,
            Type                            = parent.Type,
            Website                         = website,
            Phone                           = phone,
            Account_Location__Latitude__s   = latitude,
            Account_Location__Longitude__s  = longitude
        );
        insert subAcc;
        return subAcc.Id;
    }
}