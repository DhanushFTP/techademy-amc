/******************************************************************
 * Class Name    : WebToLeadRestService
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 22-09-2026
 * @description  : REST replacement for the standard Salesforce
 *                 Web-to-Lead form (servlet.WebToLead). External
 *                 systems (website, landing pages, ad platforms) POST
 *                 lead details and a Lead record is created.
 *
 *                 Flow:
 *                   1. Read the POST body.
 *                   2. Check the static API key in the x-api-key header.
 *                   3. Deserialize the body straight into a Lead (every
 *                      key is a Lead field API name).
 *                   4. Keep the incoming Lead Source text in Source__c
 *                      and fall back to "Other" for any picklist value
 *                      that is not configured in the org.
 *                   5. Insert the Lead.
 *                   6. Return status / hasError / message / leadId.
 *
 *                 Endpoint : POST /services/apexrest/webtolead/v1
 *                 Headers  : x-api-key: <static key>
 *                            Content-Type: application/json
 *
 *                 The API key is held on the Web_To_Lead_API_Config__mdt
 *                 record "Default" (API_Key__c) and compared
 *                 case-sensitively.
 *
 *                 Fields behind the current Web-to-Lead form:
 *                   first_name       -> FirstName
 *                   last_name        -> LastName
 *                   email            -> Email
 *                   company          -> Company
 *                   mobile           -> MobilePhone
 *                   lead_source      -> LeadSource (raw text kept in Source__c)
 *                   00N5i00000Swqbo  -> utm_medium__c
 *                   00N5i00000SwqR7  -> utm_source__c
 *
 *                 Sample request body:
 *                 {
 *                   "FirstName"     : "Asha",
 *                   "LastName"      : "Rao",
 *                   "Email"         : "asha.rao@example.com",
 *                   "Company"       : "Example Ltd",
 *                   "MobilePhone"   : "9876543210",
 *                   "LeadSource"    : "Website",
 *                   "utm_medium__c" : "cpc",
 *                   "utm_source__c" : "google"
 *                 }
 *
 *                 Responses (JSON):
 *                   201 { "status":"success", "hasError":false,
 *                         "message":"Lead saved successfully.", "leadId":"00Q..." }
 *                   400 { "status":"error", "hasError":true, "message":"..." }
 *                   401 { "status":"error", "hasError":true,
 *                         "message":"Invalid or missing API key." }
 *                   500 { "status":"error", "hasError":true, "message":"..." }
 * @author       : Naveen Kumar R
 * Used By       : - Techademy website / external lead sources
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Naveen Kumar R  | 22-09-2026 | Initial version
 * 1.1 | Naveen Kumar R  | 22-09-2026 | Deserialize straight into Lead,
 *     |                 |            | keep Lead Source text in Source__c,
 *     |                 |            | unknown picklist values become Other
 * -----------------------------------------------------------------------------
 ******************************************************************/
@RestResource(urlMapping='/webtolead/v1/*')
global with sharing class WebToLeadRestService {

    // Request header that carries the static API key.
    private static final String HEADER_API_KEY = 'x-api-key';

    // DeveloperName of the Web_To_Lead_API_Config__mdt record to use.
    private static final String CONFIG_RECORD_NAME = 'Default';

    // Placeholder shipped in source control; a key equal to this is
    // treated as "not configured" so the endpoint stays closed until
    // the real key is set in Setup.
    @TestVisible
    private static final String PLACEHOLDER_API_KEY = 'REPLACE_ME_IN_SETUP';

    // Value used when an incoming picklist value is not configured.
    @TestVisible
    private static final String FALLBACK_PICKLIST_VALUE = 'Other';

    // Lead fields, keyed by API name (lookup is case-insensitive).
    private static final Map<String, Schema.SObjectField> LEAD_FIELDS =
        Schema.SObjectType.Lead.fields.getMap();

    // Lets tests inject a config record instead of relying on the
    // deployed custom metadata.
    @TestVisible
    private static Web_To_Lead_API_Config__mdt configOverride;

    /**
    * Class Name: LeadResponse
    * @author: Naveen Kumar R
    * @description: JSON body returned to the caller for every request.
    */
    global class LeadResponse {
        public String status;    // 'success' or 'error'
        public Boolean hasError;
        public String message;
        public String leadId;
    }

    /**
    * Method Name: createLead
    * @author: Naveen Kumar R
    * @description: POST handler. Checks the API key, builds the Lead
    *               from the request body, inserts it and returns the
    *               result with the matching HTTP status code.
    * @return: void (response is written to RestContext.response)
    */
    @HttpPost
    global static void createLead() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        // 1 + 2. Read the body and check the static API key.
        Web_To_Lead_API_Config__mdt config = getConfig();
        if (!isAuthorized(req, config)) {
            writeResponse(res, 401, 'Invalid or missing API key.', null);
            return;
        }

        String jsonBody = (req.requestBody == null) ? '' : req.requestBody.toString().trim();
        if (String.isBlank(jsonBody)) {
            writeResponse(res, 400, 'Request body is required.', null);
            return;
        }

        try {
            // 3. Every key is a Lead field API name, so the platform
            //    deserializer does the mapping and type conversion.
            //    Strict mode reports a misspelled field instead of
            //    silently dropping it.
            Lead newLead = (Lead) JSON.deserializeStrict(jsonBody, Lead.class);

            // 4. Keep the incoming Lead Source text and normalize picklists.
            newLead.Source__c = newLead.LeadSource;
            applyPicklistFallback(newLead);

            // 5. Partial-success insert so validation, duplicate and
            //    assignment rule errors come back to the caller.
            Database.DMLOptions dmlOptions = new Database.DMLOptions();
            dmlOptions.assignmentRuleHeader.useDefaultRule = config.Use_Assignment_Rule__c;
            dmlOptions.optAllOrNone = false;
            Database.SaveResult result = Database.insert(newLead, dmlOptions);

            // 6. Respond.
            if (result.isSuccess()) {
                writeResponse(res, 201, 'Lead saved successfully.', result.getId());
            } else {
                List<String> messages = new List<String>();
                for (Database.Error err : result.getErrors()) {
                    messages.add(err.getMessage());
                }
                writeResponse(res, 400, String.join(messages, ' '), null);
            }
        } catch (JSONException e) {
            // Thrown for malformed JSON and for keys that are not Lead fields.
            writeResponse(res, 400, 'Invalid request body: ' + e.getMessage(), null);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'WebToLeadRestService error: '
                + e.getMessage() + '\n' + e.getStackTraceString());
            writeResponse(res, 500, 'Unexpected error while saving the Lead: '
                + e.getMessage(), null);
        }
    }

    /**
    * Method Name: applyPicklistFallback
    * @author: Naveen Kumar R
    * @description: Replaces any picklist value that is not configured
    *               in the org with "Other", so a new value coming from
    *               the website does not fail the insert. The original
    *               Lead Source text is preserved in Source__c.
    * @param: newLead - Lead built from the request body
    */
    @TestVisible
    private static void applyPicklistFallback(Lead newLead) {
        for (String fieldName : newLead.getPopulatedFieldsAsMap().keySet()) {
            Schema.SObjectField field = LEAD_FIELDS.get(fieldName);
            if (field == null) {
                continue;
            }
            Schema.DescribeFieldResult describe = field.getDescribe();
            if (describe.getType() != Schema.DisplayType.PICKLIST) {
                continue;
            }

            String value = String.valueOf(newLead.get(field));
            if (String.isBlank(value)) {
                continue;
            }

            Boolean isValid = false;
            Boolean hasFallback = false;
            for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
                if (!entry.isActive()) {
                    continue;
                }
                if (entry.getValue().equalsIgnoreCase(value)) {
                    isValid = true;
                    break;
                }
                if (entry.getValue().equalsIgnoreCase(FALLBACK_PICKLIST_VALUE)) {
                    hasFallback = true;
                }
            }
            if (!isValid && hasFallback) {
                newLead.put(field, FALLBACK_PICKLIST_VALUE);
            }
        }
    }

    /**
    * Method Name: getConfig
    * @author: Naveen Kumar R
    * @description: Returns the API config record (or the test
    *               override). Returns null when it is not deployed.
    * @return: Web_To_Lead_API_Config__mdt
    */
    @TestVisible
    private static Web_To_Lead_API_Config__mdt getConfig() {
        return (configOverride != null)
            ? configOverride
            : Web_To_Lead_API_Config__mdt.getInstance(CONFIG_RECORD_NAME);
    }

    /**
    * Method Name: isAuthorized
    * @author: Naveen Kumar R
    * @description: True when the config is active, a real key is
    *               configured and the x-api-key header matches it
    *               exactly (case-sensitive; header name is not).
    * @param: req - incoming REST request
    * @param: config - API config record
    * @return: Boolean
    */
    @TestVisible
    private static Boolean isAuthorized(RestRequest req, Web_To_Lead_API_Config__mdt config) {
        if (config == null || !config.Is_Active__c) {
            return false;
        }
        String expectedKey = config.API_Key__c;
        if (String.isBlank(expectedKey) || expectedKey == PLACEHOLDER_API_KEY) {
            return false;
        }
        String providedKey = getHeader(req, HEADER_API_KEY);
        // String.equals is case-sensitive; the == operator is not.
        return providedKey != null && expectedKey.equals(providedKey);
    }

    /**
    * Method Name: getHeader
    * @author: Naveen Kumar R
    * @description: Case-insensitive header lookup (proxies and
    *               clients may change header-name casing).
    * @param: req - incoming REST request
    * @param: name - header name
    * @return: String header value, or null when absent
    */
    private static String getHeader(RestRequest req, String name) {
        if (req == null || req.headers == null) {
            return null;
        }
        for (String headerName : req.headers.keySet()) {
            if (headerName != null && headerName.equalsIgnoreCase(name)) {
                return req.headers.get(headerName);
            }
        }
        return null;
    }

    /**
    * Method Name: writeResponse
    * @author: Naveen Kumar R
    * @description: Writes the JSON response body and status code.
    * @param: res - REST response
    * @param: statusCode - HTTP status code
    * @param: message - message for the caller
    * @param: leadId - Id of the new Lead, null on failure
    */
    private static void writeResponse(RestResponse res, Integer statusCode,
                                      String message, String leadId) {
        LeadResponse body = new LeadResponse();
        body.hasError = (leadId == null);
        body.status = body.hasError ? 'error' : 'success';
        body.message = message;
        body.leadId = leadId;

        res.statusCode = statusCode;
        res.responseBody = Blob.valueOf(JSON.serialize(body, true));
    }
}