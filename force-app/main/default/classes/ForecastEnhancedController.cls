public with sharing class ForecastEnhancedController {

    // ─── Helpers ────────────────────────────────────────────────────────────

    /** Return the userId to operate on (current user if blank). */
    private static Id resolveUserId(String userId) {
        return String.isBlank(userId) ? UserInfo.getUserId() : (Id) userId;
    }

    /** Build an empty category map. */
    private static Map<String, Decimal> emptyCats() {
        return new Map<String, Decimal>{
            'Closed' => 0, 'Commit' => 0, 'BestCase' => 0, 'Pipeline' => 0
        };
    }

    /**
     * Populate quotaByUserMonth and itemsByUserMonth for a set of user IDs
     * over the given date range (in-place).
     */
    private static void fetchForecastData(
        Set<Id> userIds, Date startDt, Date endDt,
        Map<Id, Map<String, Decimal>> quotaByUserMonth,
        Map<Id, Map<String, Map<String, Decimal>>> itemsByUserMonth
    ) {
        for (ForecastingQuota fq : [
            SELECT QuotaAmount, StartDate, QuotaOwnerId
            FROM ForecastingQuota
            WHERE QuotaOwnerId IN :userIds
              AND StartDate >= :startDt
              AND StartDate <= :endDt
            ORDER BY StartDate
        ]) {
            if (!quotaByUserMonth.containsKey(fq.QuotaOwnerId)) {
                quotaByUserMonth.put(fq.QuotaOwnerId, new Map<String, Decimal>());
            }
            quotaByUserMonth.get(fq.QuotaOwnerId).put(String.valueOf(fq.StartDate), fq.QuotaAmount);
        }

        for (ForecastingItem fi : [
            SELECT ForecastCategoryName, ForecastAmount, Period.StartDate, OwnerId
            FROM ForecastingItem
            WHERE OwnerId IN :userIds
              AND Period.StartDate >= :startDt
              AND Period.StartDate <= :endDt
            ORDER BY Period.StartDate
        ]) {
            if (!itemsByUserMonth.containsKey(fi.OwnerId)) {
                itemsByUserMonth.put(fi.OwnerId, new Map<String, Map<String, Decimal>>());
            }
            Map<String, Map<String, Decimal>> userMap = itemsByUserMonth.get(fi.OwnerId);
            String monthKey = String.valueOf(fi.Period.StartDate);
            if (!userMap.containsKey(monthKey)) {
                userMap.put(monthKey, emptyCats());
            }
            String cat = fi.ForecastCategoryName;
            if (cat == 'Closed' || cat == 'Commit' || cat == 'BestCase' || cat == 'Pipeline') {
                Map<String, Decimal> cats = userMap.get(monthKey);
                cats.put(cat, (cats.get(cat) ?? 0) + fi.ForecastAmount);
            }
        }
    }

    /** Extract a category amount safely. */
    private static Decimal getAmt(Map<String, Map<String, Decimal>> userItems, String monthKey, String cat) {
        if (userItems == null || !userItems.containsKey(monthKey)) return 0;
        Map<String, Decimal> cats = userItems.get(monthKey);
        return cats.containsKey(cat) ? cats.get(cat) : 0;
    }

    private static Decimal getQuota(Map<String, Decimal> qMap, String monthKey) {
        return (qMap != null && qMap.containsKey(monthKey)) ? qMap.get(monthKey) : 0;
    }

    // ─── Public API ──────────────────────────────────────────────────────────

    /** Returns active users for the user selector dropdown. */
    @AuraEnabled(cacheable=true)
    public static List<Map<String,String>> getUsers() {
        List<Map<String,String>> result = new List<Map<String,String>>();
        for (User u : [
            SELECT Id, Name FROM User WHERE IsActive = true ORDER BY Name LIMIT 200
        ]) {
            result.add(new Map<String,String>{ 'value' => u.Id, 'label' => u.Name });
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getForecastData(String startDate, String endDate, String userId) {
        Id targetUserId = resolveUserId(userId);
        Date startDt = Date.valueOf(startDate);
        Date endDt   = Date.valueOf(endDate);

        // ── Detect direct subordinates via role hierarchy ──────────────────
        User targetUser = [SELECT UserRoleId FROM User WHERE Id = :targetUserId LIMIT 1];
        Id targetRoleId = targetUser.UserRoleId;

        List<User> directReports = new List<User>();
        if (targetRoleId != null) {
            // Collect all child roles one level deep under the target user's role
            Set<Id> childRoleIds = new Set<Id>();
            for (UserRole r : [
                SELECT Id FROM UserRole WHERE ParentRoleId = :targetRoleId
            ]) {
                childRoleIds.add(r.Id);
            }
            if (!childRoleIds.isEmpty()) {
                directReports = [
                    SELECT Id, Name FROM User
                    WHERE UserRoleId IN :childRoleIds AND IsActive = true
                    ORDER BY Name
                ];
            }
        }
        Boolean isManager = !directReports.isEmpty();

        // ── Fetch forecast data for manager + all direct reports ───────────
        Set<Id> allUserIds = new Set<Id>{ targetUserId };
        for (User u : directReports) allUserIds.add(u.Id);

        Map<Id, Map<String, Decimal>>              quotaMap = new Map<Id, Map<String, Decimal>>();
        Map<Id, Map<String, Map<String, Decimal>>> itemsMap = new Map<Id, Map<String, Map<String, Decimal>>>();
        fetchForecastData(allUserIds, startDt, endDt, quotaMap, itemsMap);

        // ── Build monthly rows ─────────────────────────────────────────────
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        Date cursor = startDt.toStartOfMonth();

        while (cursor <= endDt) {
            String key = String.valueOf(cursor);

            // Manager totals (from manager's own ForecastingItem – Salesforce rolls up the team into this)
            Decimal totalQuota    = getQuota(quotaMap.get(targetUserId), key);
            Decimal totalClosed   = getAmt(itemsMap.get(targetUserId), key, 'Closed');
            Decimal totalCommit   = getAmt(itemsMap.get(targetUserId), key, 'Commit');
            Decimal totalBestCase = getAmt(itemsMap.get(targetUserId), key, 'BestCase');
            Decimal totalPipeline = getAmt(itemsMap.get(targetUserId), key, 'Pipeline');

            Map<String, Object> rowMap = new Map<String, Object>();
            rowMap.put('startDate', key);
            rowMap.put('quota',     totalQuota);
            rowMap.put('closed',    totalClosed);
            rowMap.put('commit',    totalCommit);
            rowMap.put('bestCase',  totalBestCase);
            rowMap.put('pipeline',  totalPipeline);

            if (isManager) {
                // Per-member breakdown: direct reports + manager's own deals (derived)
                List<Map<String, Object>> memberRows = new List<Map<String, Object>>();
                Decimal sumMemberQuota    = 0;
                Decimal sumMemberClosed   = 0;
                Decimal sumMemberCommit   = 0;
                Decimal sumMemberBestCase = 0;
                Decimal sumMemberPipeline = 0;

                for (User u : directReports) {
                    Decimal mQuota    = getQuota(quotaMap.get(u.Id), key);
                    Decimal mClosed   = getAmt(itemsMap.get(u.Id), key, 'Closed');
                    Decimal mCommit   = getAmt(itemsMap.get(u.Id), key, 'Commit');
                    Decimal mBestCase = getAmt(itemsMap.get(u.Id), key, 'BestCase');
                    Decimal mPipeline = getAmt(itemsMap.get(u.Id), key, 'Pipeline');

                    sumMemberQuota    += mQuota;
                    sumMemberClosed   += mClosed;
                    sumMemberCommit   += mCommit;
                    sumMemberBestCase += mBestCase;
                    sumMemberPipeline += mPipeline;

                    Map<String, Object> mRow = new Map<String, Object>();
                    mRow.put('userId',   u.Id);
                    mRow.put('userName', u.Name);
                    mRow.put('quota',    mQuota);
                    mRow.put('closed',   mClosed);
                    mRow.put('commit',   mCommit);
                    mRow.put('bestCase', mBestCase);
                    mRow.put('pipeline', mPipeline);
                    memberRows.add(mRow);
                }

                // Manager's own deals = total (Salesforce rollup) − sum of direct reports
                Decimal ownQuota    = totalQuota    - sumMemberQuota;
                Decimal ownClosed   = totalClosed   - sumMemberClosed;
                Decimal ownCommit   = totalCommit   - sumMemberCommit;
                Decimal ownBestCase = totalBestCase - sumMemberBestCase;
                Decimal ownPipeline = totalPipeline - sumMemberPipeline;

                Map<String, Object> ownRow = new Map<String, Object>();
                ownRow.put('userId',   targetUserId);
                ownRow.put('userName', 'Own Deals');
                ownRow.put('quota',    ownQuota    >= 0 ? ownQuota    : 0);
                ownRow.put('closed',   ownClosed   >= 0 ? ownClosed   : 0);
                ownRow.put('commit',   ownCommit   >= 0 ? ownCommit   : 0);
                ownRow.put('bestCase', ownBestCase >= 0 ? ownBestCase : 0);
                ownRow.put('pipeline', ownPipeline >= 0 ? ownPipeline : 0);
                memberRows.add(ownRow);

                rowMap.put('members', memberRows);
            }

            rows.add(rowMap);
            cursor = cursor.addMonths(1);
        }

        Map<String, Object> result = new Map<String, Object>{ 'rows' => rows };
        if (isManager) result.put('isManager', true);
        return result;
    }

    @AuraEnabled
    public static Decimal getConversionRate(String fiscalYear, String userId) {
        Id targetUserId = resolveUserId(userId);
        List<ForecastConversionRate__c> rateRecords = [
            SELECT ConversionRate__c FROM ForecastConversionRate__c
            WHERE User__c = :targetUserId AND FiscalYear__c = :fiscalYear
            LIMIT 1
        ];
        return rateRecords.isEmpty() ? null : rateRecords[0].ConversionRate__c;
    }

    @AuraEnabled
    public static void saveConversionRate(Decimal rate, String fiscalYear, String userId) {
        Id targetUserId = resolveUserId(userId);
        List<ForecastConversionRate__c> rateRecords = [
            SELECT Id FROM ForecastConversionRate__c
            WHERE User__c = :targetUserId AND FiscalYear__c = :fiscalYear
            LIMIT 1
        ];
        ForecastConversionRate__c rateRecord = rateRecords.isEmpty()
            ? new ForecastConversionRate__c(User__c = targetUserId, FiscalYear__c = fiscalYear)
            : rateRecords[0];
        rateRecord.ConversionRate__c = rate;
        upsert rateRecord;
    }

    /**
     * Returns individual Opportunity records for a clicked forecast cell.
     * forecastCategory: Closed | Commit | BestCase | Pipeline
     * Matches native Salesforce cumulative rollup behaviour.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String,Object>> getDealsForCell(
        String userId, String startDate, String forecastCategory
    ) {
        Id targetUserId = resolveUserId(userId);
        Date startDt = Date.valueOf(startDate);
        Date endDt   = startDt.toStartOfMonth().addMonths(1).addDays(-1);

        // Opportunity.ForecastCategoryName uses 'Best Case' (with space),
        // while ForecastingItem uses 'BestCase'. Map accordingly.
        Set<String> categories = new Set<String>();
        if      (forecastCategory == 'Closed')   { categories.add('Closed'); }
        else if (forecastCategory == 'Commit')   { categories.addAll(new List<String>{'Closed','Commit'}); }
        else if (forecastCategory == 'BestCase') { categories.addAll(new List<String>{'Closed','Commit','Best Case'}); }
        else if (forecastCategory == 'Pipeline') { categories.addAll(new List<String>{'Closed','Commit','Best Case','Pipeline'}); }

        // For managers, include direct reports' deals too
        Id targetRoleId = [SELECT UserRoleId FROM User WHERE Id = :targetUserId LIMIT 1].UserRoleId;
        Set<Id> ownerIds = new Set<Id>{ targetUserId };
        if (targetRoleId != null) {
            Set<Id> childRoleIds = new Set<Id>();
            for (UserRole r : [SELECT Id FROM UserRole WHERE ParentRoleId = :targetRoleId]) {
                childRoleIds.add(r.Id);
            }
            if (!childRoleIds.isEmpty()) {
                for (User u : [SELECT Id FROM User WHERE UserRoleId IN :childRoleIds AND IsActive = true]) {
                    ownerIds.add(u.Id);
                }
            }
        }

        List<Map<String,Object>> result = new List<Map<String,Object>>();
        Integer rowNum = 1;
        for (Opportunity opp : [
            SELECT Id, Name,
                   Parent_Deal__r.Name,
                   Owner.Name,
                   Account.Name,
                   Line_of_Business__c,
                   Product__c,
                   StageName,
                   Amount,
                   CloseDate,
                   AgeInDays,
                   Expected_Start_Date__c,
                   End_Date__c,
                   Training_Duration__c
            FROM Opportunity
            WHERE OwnerId IN :ownerIds
              AND CloseDate >= :startDt
              AND CloseDate <= :endDt
              AND ForecastCategoryName IN :categories
            ORDER BY CloseDate, Name
            LIMIT 200
        ]) {
            Map<String,Object> row = new Map<String,Object>();
            row.put('id',               opp.Id);
            row.put('rowNum',           rowNum++);
            row.put('name',             opp.Name);
            row.put('parentDeal',       opp.Parent_Deal__r != null ? opp.Parent_Deal__r.Name : '');
            row.put('ownerName',        opp.Owner.Name);
            row.put('accountName',      opp.Account != null ? opp.Account.Name : '');
            row.put('lineOfBusiness',   opp.Line_of_Business__c != null ? opp.Line_of_Business__c : '');
            row.put('product',          opp.Product__c != null ? opp.Product__c : '');
            row.put('stageName',        opp.StageName);
            row.put('amount',           opp.Amount != null ? opp.Amount : 0);
            row.put('closeDate',        opp.CloseDate != null ? opp.CloseDate.format() : '');
            row.put('age',              opp.AgeInDays != null ? opp.AgeInDays : 0);
            row.put('expectedStart',    opp.Expected_Start_Date__c != null
                                            ? opp.Expected_Start_Date__c.date().format() : '');
            row.put('expectedEnd',      opp.End_Date__c != null
                                            ? opp.End_Date__c.date().format() : '');
            row.put('trainingDuration', opp.Training_Duration__c != null ? opp.Training_Duration__c : '');
            result.add(row);
        }
        return result;
    }
}