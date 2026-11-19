/**
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 * Class Name      : McubeConfigController
 * Author          : Dhanush
 * Created Date    : Apr 9, 2026
 * Last Modified On: May 5, 2026
 * Description     : Saves MCube configuration.
 *                   1 record per source object.
 *                   When a config already exists for the same object (New mode),
 *                   merges new values into existing instead of full replace.
 *                   Supports two modes: BOTH (inbound + outbound) and OUTBOUND_ONLY.
 *
 * Change History  :
 *  Date          │   Author   │   Change
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 *  Apr 9,  2026  │ Dhanush    │ Initial version
 *  Apr 13, 2026  │ Dhanush    │ 1 record per source object, all numbers comma-separated
 *  Apr 20, 2026  │ Dhanush    │ Merge (not replace) when existing record found for object
 *  May 5,  2026  │ Dhanush    │ Added configMode (BOTH / OUTBOUND_ONLY) handling
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 */
public without sharing class McubeConfigController {

    @AuraEnabled
    public static void saveConfig(
        String  configName,
        String  sourceObject,
        String  duplicationRule,
        String  defaultValues,
        String  landingNumbers,
        String  landingDetails,
        String  outboundFields,
        String  callActivityMapping,
        Boolean createIfNotFound,
        Boolean isActive,
        Boolean isDefault,
        String  recordId,
        String  configMode,
        String  priority
    ) {
        MCube_Configuration__c rec;
        Boolean isMerge = false;

        if (String.isNotBlank(recordId)) {
            // ── Edit: load by Id, full replace (user is editing intentionally) ─
            rec = [
                SELECT Id, Source_Object__c, Duplication_rule__c, Default_Values__c,
                       Landing_Number__c, Outbound_Fields__c, Is_Active__c,
                       Is_Default__c, Create_If_Not_Found__c, Configuration_Mode__c
                FROM MCube_Configuration__c
                WHERE Id = :recordId LIMIT 1
            ];
        } else {
            // ── New: check if source object already has a config ─
            List<MCube_Configuration__c> existing = [
                SELECT Id, Source_Object__c, Duplication_rule__c, Default_Values__c,
                       Landing_Number__c, Outbound_Fields__c, Is_Active__c,
                       Is_Default__c, Create_If_Not_Found__c, Configuration_Mode__c
                FROM MCube_Configuration__c
                WHERE Source_Object__c = :sourceObject AND Is_Active__c = true       
                LIMIT 1
            ];
            if (!existing.isEmpty()) {
                rec = existing[0];
                isMerge = true;
            } else {
                rec = new MCube_Configuration__c();
            }
        }

        rec.Name                  = 'MCube - ' + sourceObject;
        rec.Source_Object__c      = sourceObject;
        rec.Configuration_Mode__c = String.isBlank(configMode) ? 'BOTH' : configMode;

        Boolean outboundOnly = (configMode == 'OUTBOUND_ONLY');

        if (outboundOnly) {
            // ── Outbound-only: only touch outbound-related fields ───
            // Leave Duplication_rule__c, Default_Values__c, Landing_Number__c,
            // Create_If_Not_Found__c untouched (keep existing values if any)
            rec.Outbound_Fields__c       = outboundFields;
            rec.Call_Activity_Mapping__c = callActivityMapping;
            rec.Is_Active__c             = isActive;
            rec.Is_Default__c            = isDefault;
        } else if (isMerge) {
            // ── Merge landing numbers (JSON map) ─────────────────────
            rec.Landing_Number__c = mergeLandingNumbers(rec.Landing_Number__c, landingNumbers);

            // ── Merge default values (JSON array of {field,value}) ──
            rec.Default_Values__c = mergeJsonArrayByField(rec.Default_Values__c, defaultValues, 'field');

            // ── Merge outbound fields (JSON array of {order,field,label}) ──
            rec.Outbound_Fields__c = mergeJsonArrayByField(rec.Outbound_Fields__c, outboundFields, 'field');

            // ── Dedup SOQL: replace (can't really "merge" a SOQL query) ──
            rec.Duplication_rule__c = duplicationRule;

            // ── Call activity mapping: replace (single JSON config) ──
            rec.Call_Activity_Mapping__c = callActivityMapping;

            // Priority: prefer new value (BOTH-mode only field)
            rec.Priority__c = priority;

            // Flags: prefer new values
            rec.Create_If_Not_Found__c = createIfNotFound;
            rec.Is_Active__c           = isActive;
            rec.Is_Default__c          = isDefault;
        } else {
            // ── Full write (new record or edit mode) ─────────────────
            rec.Duplication_rule__c      = duplicationRule;
            rec.Default_Values__c        = defaultValues;
            rec.Landing_Number__c        = landingNumbers;
            rec.Outbound_Fields__c       = outboundFields;
            rec.Call_Activity_Mapping__c = callActivityMapping;
            rec.Priority__c              = priority;
            rec.Create_If_Not_Found__c   = createIfNotFound;
            rec.Is_Active__c           = isActive;
            rec.Is_Default__c          = isDefault;
        }

        if (rec.Id == null) { insert rec; }
        else                { update rec; }

        // ── Sync landing numbers to the Mcube_Landing_Number__c object ──
        // (inbound flows only; outbound-only configs don't manage landing numbers)
        if (!outboundOnly) {
            syncLandingNumbers(rec.Id, landingDetails);
        }
    }

    /**
     * Upserts landing-number records into Mcube_Landing_Number__c and links them
     * to the given configuration. Existing records are matched by Number__c
     * (the phone number); a match is updated, otherwise a new record is created.
     * Rows removed from the wizard are left untouched (never deleted).
     *
     * @param configId            The MCube_Configuration__c record Id.
     * @param landingDetailsJson  JSON array of {source, number, campaign}.
     */
    private static void syncLandingNumbers(Id configId, String landingDetailsJson) {
        if (String.isBlank(landingDetailsJson)) return;

        List<LandingDetail> details;
        try {
            details = (List<LandingDetail>) JSON.deserialize(landingDetailsJson, List<LandingDetail>.class);
        } catch (Exception e) {
            return;
        }
        if (details == null || details.isEmpty()) return;

        // Find existing records by their Number__c value
        Set<String> numbers = new Set<String>();
        for (LandingDetail d : details) {
            if (String.isNotBlank(d.num)) numbers.add(d.num);
        }
        if (numbers.isEmpty()) return;

        Map<String, Mcube_Landing_Number__c> existingByNumber = new Map<String, Mcube_Landing_Number__c>();
        for (Mcube_Landing_Number__c ln : [
            SELECT Id, Number__c FROM Mcube_Landing_Number__c WHERE Number__c IN :numbers
        ]) {
            if (!existingByNumber.containsKey(ln.Number__c)) {
                existingByNumber.put(ln.Number__c, ln);
            }
        }

        // Build the upsert set keyed by number (dedupes repeated numbers)
        Map<String, Mcube_Landing_Number__c> toUpsert = new Map<String, Mcube_Landing_Number__c>();
        for (LandingDetail d : details) {
            if (String.isBlank(d.num)) continue;
            Mcube_Landing_Number__c ln = existingByNumber.containsKey(d.num)
                ? existingByNumber.get(d.num)
                : new Mcube_Landing_Number__c();
            ln.Number__c              = d.num;
            ln.Source__c              = d.source;
            ln.Campaign_Name__c       = d.campaign;
            ln.MCube_Configuration__c = configId;
            toUpsert.put(d.num, ln);
        }

        if (!toUpsert.isEmpty()) upsert toUpsert.values();
    }

    public class LandingDetail {
        @AuraEnabled public String source;
        @AuraEnabled public String num;       // landing number ('number' is a reserved word in Apex)
        @AuraEnabled public String campaign;
    }

    /**
     * Loads the landing-number rows (source, number, campaign) linked to a config,
     * for repopulating the wizard's Step 4 in edit mode.
     */
    @AuraEnabled(cacheable=true)
    public static List<LandingDetail> getLandingNumbers(String recordId) {
        List<LandingDetail> result = new List<LandingDetail>();
        if (String.isBlank(recordId)) return result;
        for (Mcube_Landing_Number__c ln : [
            SELECT Source__c, Number__c, Campaign_Name__c
            FROM Mcube_Landing_Number__c
            WHERE MCube_Configuration__c = :recordId
            ORDER BY CreatedDate
        ]) {
            LandingDetail d = new LandingDetail();
            d.source   = ln.Source__c;
            d.num   = ln.Number__c;
            d.campaign = ln.Campaign_Name__c;
            result.add(d);
        }
        return result;
    }

    @AuraEnabled(cacheable=false)
    public static Id checkExistingConfig(String sourceObject) {
        List<MCube_Configuration__c> existing = [
            SELECT Id
            FROM MCube_Configuration__c
            WHERE Source_Object__c = :sourceObject
            AND Is_Active__c = true
            LIMIT 1
        ];
        return existing.isEmpty() ? null : existing[0].Id;
    }

    /**
     * Fetches all available Salesforce objects that are createable and updateable
     * Returns ObjectInfo with apiName and label, sorted alphabetically by label
     */
    @AuraEnabled(cacheable=true)
    public static List<ObjectInfo> getAllObjects() {
        List<ObjectInfo> result = new List<ObjectInfo>();
        
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        List<String> objectNames = new List<String>(gd.keySet());
        objectNames.sort();
        
        for (String objName : objectNames) {
            Schema.SObjectType sobjType = gd.get(objName);
            Schema.DescribeSObjectResult describe = sobjType.getDescribe();
            
            // Only include createable, updateable objects that are not custom settings
            if (describe.isCreateable() && describe.isUpdateable() && !describe.isCustomSetting()) {
                ObjectInfo oi = new ObjectInfo();
                oi.apiName = describe.getName();
                oi.label = describe.getLabel();
                result.add(oi);
            }
        }
        
        result.sort();
        return result;
    }

    /**
     * Data class to hold object information
     */
    public class ObjectInfo implements Comparable {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        
        public Integer compareTo(Object other) {
            return this.label.compareTo(((ObjectInfo) other).label);
        }
    }

    // ────────────────────────────────────────────────────────────────
    // Helper: merge landing number maps
    // oldJson / newJson look like: {"Newspaper":["001","002"],"Digital":["003"]}
    // Result: sources union'd, numbers within each source union'd (dedup'd)
    // ────────────────────────────────────────────────────────────────
    private static String mergeLandingNumbers(String oldJson, String newJson) {
        Map<String, Object> oldMap = parseMapSafe(oldJson);
        Map<String, Object> newMap = parseMapSafe(newJson);

        Map<String, List<String>> merged = new Map<String, List<String>>();

        for (String src : oldMap.keySet()) {
            merged.put(src, toStringList(oldMap.get(src)));
        }
        for (String src : newMap.keySet()) {
            List<String> incoming = toStringList(newMap.get(src));
            if (!merged.containsKey(src)) {
                merged.put(src, incoming);
            } else {
                Set<String> existingNums = new Set<String>(merged.get(src));
                for (String n : incoming) {
                    if (!existingNums.contains(n)) {
                        merged.get(src).add(n);
                        existingNums.add(n);
                    }
                }
            }
        }
        return JSON.serialize(merged);
    }

    // ────────────────────────────────────────────────────────────────
    // Helper: merge a JSON array of objects, keyed by a specific field
    // e.g. [{field:"LastName",value:"X"}] — new entries override old
    // for the same `field` key, and new-only entries are appended.
    // ────────────────────────────────────────────────────────────────
    private static String mergeJsonArrayByField(String oldJson, String newJson, String keyName) {
        List<Object> oldList = parseListSafe(oldJson);
        List<Object> newList = parseListSafe(newJson);

        Map<String, Object> byKey = new Map<String, Object>();
        List<String> orderedKeys  = new List<String>();

        for (Object o : oldList) {
            Map<String, Object> m = (Map<String, Object>) o;
            String k = String.valueOf(m.get(keyName));
            if (!byKey.containsKey(k)) orderedKeys.add(k);
            byKey.put(k, m);
        }
        for (Object o : newList) {
            Map<String, Object> m = (Map<String, Object>) o;
            String k = String.valueOf(m.get(keyName));
            if (!byKey.containsKey(k)) orderedKeys.add(k);
            byKey.put(k, m);
        }

        List<Object> result = new List<Object>();
        for (String k : orderedKeys) result.add(byKey.get(k));
        return JSON.serialize(result);
    }

    private static Map<String, Object> parseMapSafe(String s) {
        if (String.isBlank(s)) return new Map<String, Object>();
        try { return (Map<String, Object>) JSON.deserializeUntyped(s); }
        catch (Exception e) { return new Map<String, Object>(); }
    }

    private static List<Object> parseListSafe(String s) {
        if (String.isBlank(s)) return new List<Object>();
        try { return (List<Object>) JSON.deserializeUntyped(s); }
        catch (Exception e) { return new List<Object>(); }
    }

    private static List<String> toStringList(Object o) {
        List<String> out = new List<String>();
        if (o instanceof List<Object>) {
            for (Object x : (List<Object>) o) out.add(String.valueOf(x));
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<FieldInfo> getObjectFields(String objectName) {
        List<FieldInfo> result = new List<FieldInfo>();
        if (String.isBlank(objectName)) return result;

        Schema.SObjectType sobjType = Schema.getGlobalDescribe().get(objectName);
        if (sobjType == null) return result;

        Map<String, Schema.SObjectField> fieldMap = sobjType.getDescribe().fields.getMap();
        Set<String> skip = new Set<String>{
            'createdbyid','createddate','lastmodifiedbyid','lastmodifieddate',
            'systemmodstamp','isdeleted','lastactivitydate','lastvieweddate',
            'lastreferenceddate'
        };

        for (String fName : fieldMap.keySet()) {
            Schema.DescribeFieldResult d = fieldMap.get(fName).getDescribe();
            if (!d.isAccessible()) continue;
            if (skip.contains(d.getName().toLowerCase())) continue;

            FieldInfo fi = new FieldInfo();
            fi.apiName     = d.getName();
            fi.label       = d.getLabel();
            fi.type        = String.valueOf(d.getType());
            fi.isRequired  = !d.isNillable() && !d.isDefaultedOnCreate() && d.isCreateable();
            fi.isLookup    = (d.getType() == Schema.DisplayType.REFERENCE);
            if (fi.isLookup && !d.getReferenceTo().isEmpty()) {
                String preferred = null;
                for (Schema.SObjectType ref : d.getReferenceTo()) {
                    String refName = ref.getDescribe().getName();
                    if (refName == 'User') { preferred = 'User'; break; }   // prefer User for polymorphic
                    if (preferred == null) preferred = refName;             // else fall back to first
                }
                fi.referenceTo = preferred;
            }
            result.add(fi);
        }
        result.sort();
        return result;
    }

    public class FieldInfo implements Comparable {
        @AuraEnabled public String  apiName;
        @AuraEnabled public String  label;
        @AuraEnabled public String  type;
        @AuraEnabled public Boolean isRequired;
        @AuraEnabled public Boolean isLookup;
        @AuraEnabled public String  referenceTo;

        public Integer compareTo(Object other) {
            return this.label.compareTo(((FieldInfo) other).label);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getMcubeFields() {
        return McubeConfigDTO.getFieldNames();
    }

    /**
     * Loads ONLY the Call Activity mapping JSON for a config record.
     * Kept separate from the LWC's getRecord wire so this feature never
     * influences the existing source-object / dedup / defaults loading.
     */
    @AuraEnabled(cacheable=true)
    public static String getCallActivityMapping(String recordId) {
        if (String.isBlank(recordId)) return null;
        List<MCube_Configuration__c> recs = [
            SELECT Call_Activity_Mapping__c
            FROM MCube_Configuration__c
            WHERE Id = :recordId LIMIT 1
        ];
        return recs.isEmpty() ? null : recs[0].Call_Activity_Mapping__c;
    }
}