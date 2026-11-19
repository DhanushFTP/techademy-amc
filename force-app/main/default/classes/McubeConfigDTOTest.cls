/**
 * Tests for McubeConfigDTO.
 *
 * getFieldNames() is the contract the config wizard's mapping UI is built on:
 * McubeConfigController.getMcubeFields() serves it to the LWC, and
 * mcubeCallActivityController.createMappedRecord() resolves mapping values
 * against the same names. A silent field rename should fail here.
 */
@isTest
private class McubeConfigDTOTest {

    @isTest
    static void getFieldNames_returnsAllTwentyFields() {
        Test.startTest();
        List<String> names = McubeConfigDTO.getFieldNames();
        Test.stopTest();

        // JSON.deserializeUntyped returns an unordered Map — never assert by index.
        Set<String> asSet = new Set<String>(names);
        System.assertEquals(20, asSet.size(), 'McubeConfigDTO declares 20 fields');

        for (String expected : new List<String>{
            'callId', 'callType', 'relatedTo', 'recordUrl', 'agentNumber',
            'callStatus', 'customerNumber', 'startTime', 'endTime', 'isCallback',
            'callDuration', 'groupName', 'landingNumber', 'agentStatus', 'customStatus',
            'dispositionStatus', 'dispositionComments', 'answeredDuration', 'agentName',
            'disconnectedBy'
        }) {
            System.assert(asSet.contains(expected), 'Expected DTO field ' + expected);
        }
    }
}