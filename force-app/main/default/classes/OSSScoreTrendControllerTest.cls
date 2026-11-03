/******************************************************************
 * Class Name    : OSSScoreTrendControllerTest
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 22-05-2026
 * @description  : Tests for OSSScoreTrendController covering empty
 *                 history, populated history, and a null Opportunity Id.
 * @author       : Naveen Kumar R
 * Used By       : - OSSScoreTrendController
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Naveen Kumar R  | 22-05-2026 | Initial version
 * -----------------------------------------------------------------------------
 ******************************************************************/
@isTest
private class OSSScoreTrendControllerTest {

    /**
    * Method Name: testEmptyHistoryReturnsEmptyArray
    * @author: Naveen Kumar R
    * @description: A freshly inserted Opportunity has no history; the
    *               controller exposes '[]'.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testEmptyHistoryReturnsEmptyArray() {
        Opportunity opp = new Opportunity(
            Name = 'OSS Trend Empty',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Expected_Start_Date__c = Date.today().addDays(1),
            End_Date__c = Date.today().addDays(40)
        );
        insert opp;

        ApexPages.StandardController std = new ApexPages.StandardController(opp);
        OSSScoreTrendController ctrl = new OSSScoreTrendController(std);
        System.assertEquals('[]', ctrl.historyJson, 'Empty history should map to []');
    }

    /**
    * Method Name: testExistingHistoryReturnsJson
    * @author: Naveen Kumar R
    * @description: When OSS_Score_History__c holds JSON the controller
    *               returns it verbatim.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testExistingHistoryReturnsJson() {
        Opportunity opp = new Opportunity(
            Name = 'OSS Trend With History',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Expected_Start_Date__c = Date.today().addDays(1),
            End_Date__c = Date.today().addDays(40),
            OSS_Score_History__c = '[{"date":"2026-05-01","user":"Test User","score":100}]'
        );
        insert opp;

        ApexPages.StandardController std = new ApexPages.StandardController(opp);
        OSSScoreTrendController ctrl = new OSSScoreTrendController(std);
        System.assertNotEquals('[]', ctrl.historyJson, 'History should not be empty');
        System.assert(ctrl.historyJson.contains('100'), 'History JSON should contain the score');
    }

    /**
    * Method Name: testNullIdReturnsEmptyArray
    * @author: Naveen Kumar R
    * @description: Without a record Id the controller returns '[]'.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testNullIdReturnsEmptyArray() {
        ApexPages.StandardController std = new ApexPages.StandardController(new Opportunity());
        OSSScoreTrendController ctrl = new OSSScoreTrendController(std);
        System.assertEquals('[]', ctrl.historyJson, 'Null Id should map to []');
    }
}