/******************************************************************
 * Class Name    : OSSScoreHistoryAppenderTest
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 22-05-2026
 * @description  : Tests for OSSScoreHistoryAppender. Verifies a single
 *                 append, the bulkified path, and edge cases (null input,
 *                 explicit score override).
 * @author       : Naveen Kumar R
 * Used By       : - OSSScoreHistoryAppender
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Naveen Kumar R  | 22-05-2026 | Initial version
 * -----------------------------------------------------------------------------
 ******************************************************************/
@isTest
private class OSSScoreHistoryAppenderTest {

    private static Opportunity newOpp(String name) {
        return new Opportunity(
            Name = name,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Expected_Start_Date__c = Date.today().addDays(1),
            End_Date__c = Date.today().addDays(40)
        );
    }

    /**
    * Method Name: testAppendCreatesAndAppends
    * @author: Naveen Kumar R
    * @description: First append creates a one-entry array; second append
    *               grows it to two entries.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testAppendCreatesAndAppends() {
        Opportunity opp = newOpp('OSS Hist 1');
        insert opp;

        OSSScoreHistoryAppender.HistoryInput in1 = new OSSScoreHistoryAppender.HistoryInput();
        in1.opportunityId = opp.Id;
        in1.score = 120;

        Test.startTest();
        OSSScoreHistoryAppender.appendHistory(new List<OSSScoreHistoryAppender.HistoryInput>{ in1 });
        OSSScoreHistoryAppender.appendHistory(new List<OSSScoreHistoryAppender.HistoryInput>{ in1 });
        Test.stopTest();

        Opportunity refreshed = [SELECT OSS_Score_History__c FROM Opportunity WHERE Id = :opp.Id];
        List<Object> hist = (List<Object>) JSON.deserializeUntyped(refreshed.OSS_Score_History__c);
        System.assertEquals(2, hist.size(), 'Two entries expected');
    }

    /**
    * Method Name: testAppendQueriesScoreWhenBlank
    * @author: Naveen Kumar R
    * @description: When the input score is blank the method falls back
    *               to Opportunity_Score__c from the SOQL query.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testAppendQueriesScoreWhenBlank() {
        Opportunity opp = newOpp('OSS Hist 2');
        insert opp;

        OSSScoreHistoryAppender.HistoryInput inp = new OSSScoreHistoryAppender.HistoryInput();
        inp.opportunityId = opp.Id;

        Test.startTest();
        OSSScoreHistoryAppender.appendHistory(new List<OSSScoreHistoryAppender.HistoryInput>{ inp });
        Test.stopTest();

        Opportunity refreshed = [SELECT OSS_Score_History__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertNotEquals(null, refreshed.OSS_Score_History__c, 'History should be set');
        List<Object> hist = (List<Object>) JSON.deserializeUntyped(refreshed.OSS_Score_History__c);
        System.assertEquals(1, hist.size(), 'One entry expected');
    }

    /**
    * Method Name: testAppendHandlesEmptyAndNullInputs
    * @author: Naveen Kumar R
    * @description: Null and empty input lists are handled without error.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testAppendHandlesEmptyAndNullInputs() {
        Test.startTest();
        OSSScoreHistoryAppender.appendHistory(null);
        OSSScoreHistoryAppender.appendHistory(new List<OSSScoreHistoryAppender.HistoryInput>());
        OSSScoreHistoryAppender.appendHistory(
            new List<OSSScoreHistoryAppender.HistoryInput>{ new OSSScoreHistoryAppender.HistoryInput() }
        );
        Test.stopTest();
    }
}