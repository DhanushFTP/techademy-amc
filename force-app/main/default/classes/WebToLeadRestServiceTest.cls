/******************************************************************
 * Class Name    : WebToLeadRestServiceTest
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 22-09-2026
 * @description  : Tests for WebToLeadRestService. Covers successful
 *                 Lead creation, the Source__c copy, the picklist
 *                 fallback to "Other", API key checks (missing, wrong,
 *                 wrong case, inactive, placeholder) and bad bodies.
 * @author       : Naveen Kumar R
 * Used By       : - WebToLeadRestService
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Naveen Kumar R  | 22-09-2026 | Initial version
 * 1.1 | Naveen Kumar R  | 22-09-2026 | Aligned with Source__c + picklist
 *     |                 |            | fallback behaviour
 * -----------------------------------------------------------------------------
 ******************************************************************/
@isTest
private class WebToLeadRestServiceTest {

    private static final String TEST_KEY = 'unit-test-key-Abc123';

    // Injects an in-memory config so tests don't depend on the
    // deployed custom metadata record. Custom metadata fields are not
    // writeable in Apex, so the record is built via JSON.
    private static void setConfig(String apiKey, Boolean isActive) {
        WebToLeadRestService.configOverride = (Web_To_Lead_API_Config__mdt) JSON.deserialize(
            JSON.serialize(new Map<String, Object>{
                'DeveloperName'          => 'Default',
                'API_Key__c'             => apiKey,
                'Is_Active__c'           => isActive,
                'Use_Assignment_Rule__c' => false
            }),
            Web_To_Lead_API_Config__mdt.class
        );
    }

    // Builds the RestContext and calls the POST handler.
    private static Map<String, Object> callService(String apiKey, String jsonBody) {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/webtolead/v1';
        req.httpMethod = 'POST';
        if (apiKey != null) {
            req.addHeader('x-api-key', apiKey);
        }
        req.requestBody = Blob.valueOf(jsonBody == null ? '' : jsonBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        WebToLeadRestService.createLead();

        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        result.put('statusCode', RestContext.response.statusCode);
        return result;
    }

    private static String anyLeadSource() {
        for (Schema.PicklistEntry entry : Lead.LeadSource.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return null;
    }

    private static Map<String, Object> validBody() {
        return new Map<String, Object>{
            'FirstName'     => 'Asha',
            'LastName'      => 'Rao',
            'Email'         => 'asha.rao.w2l@example.com',
            'Company'       => 'Example Ltd',
            'MobilePhone'   => '9876543210',
            'LeadSource'    => anyLeadSource(),
            'utm_medium__c' => 'cpc',
            'utm_source__c' => 'google'
        };
    }

    @isTest
    static void createsLeadFromLeadApiNames() {
        setConfig(TEST_KEY, true);
        Map<String, Object> body = validBody();

        Test.startTest();
        Map<String, Object> result = callService(TEST_KEY, JSON.serialize(body));
        Test.stopTest();

        System.assertEquals(201, result.get('statusCode'), 'Response: ' + result);
        System.assertEquals('success', result.get('status'));
        System.assertEquals(false, result.get('hasError'));
        System.assertEquals('Lead saved successfully.', result.get('message'));

        Lead created = [
            SELECT FirstName, LastName, Email, Company, MobilePhone, LeadSource,
                   Source__c, utm_medium__c, utm_source__c
            FROM Lead
            WHERE Id = :(Id) result.get('leadId')
        ];
        System.assertEquals('Asha', created.FirstName);
        System.assertEquals('Rao', created.LastName);
        System.assertEquals('asha.rao.w2l@example.com', created.Email);
        System.assertEquals('Example Ltd', created.Company);
        System.assertEquals('9876543210', created.MobilePhone);
        System.assertEquals(body.get('LeadSource'), created.LeadSource);
        System.assertEquals(body.get('LeadSource'), created.Source__c,
            'Incoming Lead Source should be copied to Source__c');
        System.assertEquals('cpc', created.utm_medium__c);
        System.assertEquals('google', created.utm_source__c);
    }

    @isTest
    static void unknownPicklistValueFallsBackToOther() {
        setConfig(TEST_KEY, true);
        Map<String, Object> body = validBody();
        body.put('LeadSource', 'Brand New Channel');

        Map<String, Object> result = callService(TEST_KEY, JSON.serialize(body));

        System.assertEquals(201, result.get('statusCode'), 'Response: ' + result);
        Lead created = [
            SELECT LeadSource, Source__c FROM Lead WHERE Id = :(Id) result.get('leadId')
        ];
        System.assertEquals(WebToLeadRestService.FALLBACK_PICKLIST_VALUE, created.LeadSource,
            'Unconfigured picklist value should fall back to Other');
        System.assertEquals('Brand New Channel', created.Source__c,
            'Source__c should keep the value the website sent');
    }

    @isTest
    static void fieldNameLookupIsCaseInsensitive() {
        setConfig(TEST_KEY, true);
        Map<String, Object> result = callService(TEST_KEY, JSON.serialize(
            new Map<String, Object>{
                'lastname' => 'Lower Case',
                'company'  => 'Example Ltd'
            }
        ));

        System.assertEquals(201, result.get('statusCode'), 'Response: ' + result);
        Lead created = [SELECT LastName FROM Lead WHERE Id = :(Id) result.get('leadId')];
        System.assertEquals('Lower Case', created.LastName);
    }

    @isTest
    static void rejectsMissingApiKey() {
        setConfig(TEST_KEY, true);
        Map<String, Object> result = callService(null, JSON.serialize(validBody()));
        System.assertEquals(401, result.get('statusCode'));
        System.assertEquals('error', result.get('status'));
        System.assertEquals(true, result.get('hasError'));
        System.assertEquals(0, [SELECT COUNT() FROM Lead]);
    }

    @isTest
    static void rejectsWrongApiKey() {
        setConfig(TEST_KEY, true);
        Map<String, Object> result = callService('wrong-key', JSON.serialize(validBody()));
        System.assertEquals(401, result.get('statusCode'));
    }

    @isTest
    static void apiKeyComparisonIsCaseSensitive() {
        setConfig(TEST_KEY, true);
        Map<String, Object> result = callService(TEST_KEY.toUpperCase(), JSON.serialize(validBody()));
        System.assertEquals(401, result.get('statusCode'));
    }

    @isTest
    static void rejectsWhenConfigInactive() {
        setConfig(TEST_KEY, false);
        Map<String, Object> result = callService(TEST_KEY, JSON.serialize(validBody()));
        System.assertEquals(401, result.get('statusCode'));
    }

    @isTest
    static void rejectsWhenKeyIsPlaceholder() {
        setConfig(WebToLeadRestService.PLACEHOLDER_API_KEY, true);
        Map<String, Object> result = callService(
            WebToLeadRestService.PLACEHOLDER_API_KEY, JSON.serialize(validBody()));
        System.assertEquals(401, result.get('statusCode'));
    }

    @isTest
    static void rejectsUnknownField() {
        setConfig(TEST_KEY, true);
        Map<String, Object> body = validBody();
        body.put('not_a_field__c', 'x');

        Map<String, Object> result = callService(TEST_KEY, JSON.serialize(body));

        System.assertEquals(400, result.get('statusCode'));
        System.assertEquals(true, result.get('hasError'));
    }

    @isTest
    static void rejectsEmptyBody() {
        setConfig(TEST_KEY, true);
        Map<String, Object> result = callService(TEST_KEY, '');
        System.assertEquals(400, result.get('statusCode'));
        System.assertEquals('Request body is required.', result.get('message'));
    }

    @isTest
    static void rejectsMalformedJson() {
        setConfig(TEST_KEY, true);
        Map<String, Object> result = callService(TEST_KEY, '{ "LastName": ');
        System.assertEquals(400, result.get('statusCode'));
        System.assertEquals(true, result.get('hasError'));
    }

    @isTest
    static void returnsPlatformValidationErrors() {
        setConfig(TEST_KEY, true);
        // LastName and Company are required by the platform.
        Map<String, Object> result = callService(TEST_KEY, JSON.serialize(
            new Map<String, Object>{ 'Email' => 'no.name@example.com' }
        ));

        System.assertEquals(400, result.get('statusCode'));
        System.assertEquals('error', result.get('status'));
        System.assert(String.isNotBlank((String) result.get('message')),
            'DML error should be reported in the message');
    }
}