/******************************************************************
 * Class Name    : DealOSSCalculationControllerTest
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 22-05-2026
 * @description  : Test class for DealOSSCalculationController. Covers the
 *                 dashboard build, answer-to-choice matching, edge cases,
 *                 and the Deal Strategy Summary calculation.
 * @author       : Naveen Kumar R
 * Used By       : - DealOSSCalculationController
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Naveen Kumar R  | 22-05-2026 | Initial version
 * -----------------------------------------------------------------------------
 ******************************************************************/
@isTest
private class DealOSSCalculationControllerTest {

    /**
    * Method Name: getSampleMaster
    * @author: Naveen Kumar R
    * @description: Returns one Deal OSS Calculation Master metadata record
    *               with all fields, used as test data for the row tests.
    * @parameters: None
    * @return: Deal_OSS_Calculation_Master__mdt - a sample record, or null
    *          when no master records exist in the org.
    */
    private static Deal_OSS_Calculation_Master__mdt getSampleMaster() {
        List<Deal_OSS_Calculation_Master__mdt> recs = [
            SELECT MasterLabel, Question__c,
                   Choice_A__c, Choice_A_Score__c, Choice_A_Recommendation__c,
                   Choice_A_Talk_Track__c, Choice_A_Risk_Flag__c,
                   Choice_A_Action_Plan__c, Choice_A_Likely_Objection_Response__c,
                   Choice_B__c, Choice_B_Score__c, Choice_B_Recommendation__c,
                   Choice_B_Talk_Track__c, Choice_B_Risk_Flag__c,
                   Choice_B_Action_Plan__c, Choice_B_Likely_Objection_Response__c,
                   Choice_C__c, Choice_C_Score__c, Choice_C_Recommendation__c,
                   Choice_C_Talk_Track__c, Choice_C_Risk_Flag__c,
                   Choice_C_Action_Plan__c, Choice_C_Likely_Objection_Response__c,
                   Choice_D__c, Choice_D_Score__c, Choice_D_Recommendation__c,
                   Choice_D_Talk_Track__c, Choice_D_Risk_Flag__c,
                   Choice_D_Action_Plan__c, Choice_D_Likely_Objection_Response__c
            FROM Deal_OSS_Calculation_Master__mdt
            LIMIT 1
        ];
        return recs.isEmpty() ? null : recs[0];
    }

    /**
    * Method Name: testGetDashboardReturnsTwentyRows
    * @author: Naveen Kumar R
    * @description: Verifies getDashboard returns 20 question rows and a
    *               populated Deal Strategy Summary for a real Opportunity.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testGetDashboardReturnsTwentyRows() {
        Opportunity opp = new Opportunity(
            Name = 'OSS Test Opportunity',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Expected_Start_Date__c = Date.today().addDays(1),
            End_Date__c = Date.today().addDays(40)
        );
        insert opp;

        Test.startTest();
        DealOSSCalculationController.DashboardDTO dto =
            DealOSSCalculationController.getDashboard(opp.Id);
        Test.stopTest();

        System.assertEquals(20, dto.rows.size(), 'Dashboard should return 20 question rows');
        System.assertEquals(1, dto.rows[0].slNo, 'First row should be question 1');
        System.assertNotEquals(null, dto.strategy, 'Strategy summary should be populated');
        System.assertNotEquals(null, dto.strategy.youAreCurrently, 'You are currently should be set');
        System.assertNotEquals(null, dto.strategy.hardStopAlert, 'Hard-stop alert should be set');
    }

    /**
    * Method Name: testGetDashboardWithNullId
    * @author: Naveen Kumar R
    * @description: Verifies getDashboard still returns 20 rows when called
    *               with a null record Id.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testGetDashboardWithNullId() {
        Test.startTest();
        DealOSSCalculationController.DashboardDTO dto =
            DealOSSCalculationController.getDashboard(null);
        Test.stopTest();

        System.assertEquals(20, dto.rows.size(), 'Should still return 20 rows for a null record');
    }

    /**
    * Method Name: testBuildRowMatchesEachChoice
    * @author: Naveen Kumar R
    * @description: Verifies buildRow returns the correct score for each of
    *               the four choices (A, B, C, D) of a master record.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testBuildRowMatchesEachChoice() {
        Deal_OSS_Calculation_Master__mdt rec = getSampleMaster();
        if (rec == null) {
            return; // master not deployed in this org
        }

        DealOSSCalculationController.RowDTO a =
            DealOSSCalculationController.buildRow(1, 'Field__c', rec.Choice_A__c, rec, true);
        System.assertEquals(rec.Choice_A_Score__c, a.score, 'Choice A score should match');

        DealOSSCalculationController.RowDTO b =
            DealOSSCalculationController.buildRow(2, 'Field__c', rec.Choice_B__c, rec, true);
        System.assertEquals(rec.Choice_B_Score__c, b.score, 'Choice B score should match');

        DealOSSCalculationController.RowDTO c =
            DealOSSCalculationController.buildRow(3, 'Field__c', rec.Choice_C__c, rec, true);
        System.assertEquals(rec.Choice_C_Score__c, c.score, 'Choice C score should match');

        DealOSSCalculationController.RowDTO d =
            DealOSSCalculationController.buildRow(4, 'Field__c', rec.Choice_D__c, rec, true);
        System.assertEquals(rec.Choice_D_Score__c, d.score, 'Choice D score should match');
    }

    /**
    * Method Name: testBuildRowEdgeCases
    * @author: Naveen Kumar R
    * @description: Verifies buildRow handles the edge cases - unanswered
    *               question, missing Opportunity field, and an answer that
    *               does not match any master option.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testBuildRowEdgeCases() {
        Deal_OSS_Calculation_Master__mdt rec = getSampleMaster();

        DealOSSCalculationController.RowDTO unanswered =
            DealOSSCalculationController.buildRow(1, 'Field__c', null, rec, true);
        System.assertEquals(null, unanswered.score, 'Unanswered row should have no score');

        DealOSSCalculationController.RowDTO missingField =
            DealOSSCalculationController.buildRow(2, 'Bad_Field__c', 'Anything', rec, false);
        System.assertNotEquals(null, missingField.note, 'Missing field should set a note');

        if (rec != null) {
            DealOSSCalculationController.RowDTO noMatch =
                DealOSSCalculationController.buildRow(3, 'Field__c', 'value-not-in-master', rec, true);
            System.assertNotEquals(null, noMatch.note, 'Unmatched answer should set a note');
        }
    }

    /**
    * Method Name: makeRows
    * @author: Naveen Kumar R
    * @description: Builds a fresh list of 20 RowDTO entries with a default
    *               score, used to set up buildStrategy test scenarios.
    * @parameters:
    *     - Decimal defaultScore: Score to set on every row.
    * @return: List<DealOSSCalculationController.RowDTO> - 20 test rows.
    */
    private static List<DealOSSCalculationController.RowDTO> makeRows(Decimal defaultScore) {
        List<DealOSSCalculationController.RowDTO> rows = new List<DealOSSCalculationController.RowDTO>();
        for (Integer i = 1; i <= 20; i++) {
            DealOSSCalculationController.RowDTO r = new DealOSSCalculationController.RowDTO();
            r.slNo = i;
            r.score = defaultScore;
            r.yourAnswer = 'Test answer';
            rows.add(r);
        }
        return rows;
    }

    /**
    * Method Name: testBuildStrategyHighScore
    * @author: Naveen Kumar R
    * @description: Verifies the high-score (>=151) branches of the Deal
    *               Strategy Summary fire with no qualification gaps.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testBuildStrategyHighScore() {
        List<DealOSSCalculationController.RowDTO> rows = makeRows(2);
        Test.startTest();
        DealOSSCalculationController.StrategyDTO s =
            DealOSSCalculationController.buildStrategy(rows, 192);
        Test.stopTest();
        System.assert(s.youAreCurrently.contains('qualified deal with momentum'),
            'Expect high-score message');
        System.assertEquals('None', s.missing, 'No gaps expected');
        System.assert(s.hardStopAlert.contains('No hard-stop'), 'Expect no hard stop');
        System.assert(s.topPerformerBenchmark.contains('relationship warm'),
            'Expect >=151 top performer message');
    }

    /**
    * Method Name: testBuildStrategyMediumScore
    * @author: Naveen Kumar R
    * @description: Verifies the medium-score (>=101) branch of the Deal
    *               Strategy Summary.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testBuildStrategyMediumScore() {
        List<DealOSSCalculationController.RowDTO> rows = makeRows(2);
        Test.startTest();
        DealOSSCalculationController.StrategyDTO s =
            DealOSSCalculationController.buildStrategy(rows, 120);
        Test.stopTest();
        System.assert(s.youAreCurrently.contains('promising deal'),
            'Expect >=101 message');
    }

    /**
    * Method Name: testBuildStrategyMediumLowScore
    * @author: Naveen Kumar R
    * @description: Verifies the medium-low (>=51) branch of the Deal
    *               Strategy Summary.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testBuildStrategyMediumLowScore() {
        List<DealOSSCalculationController.RowDTO> rows = makeRows(2);
        Test.startTest();
        DealOSSCalculationController.StrategyDTO s =
            DealOSSCalculationController.buildStrategy(rows, 75);
        Test.stopTest();
        System.assert(s.youAreCurrently.contains('under-qualified'),
            'Expect >=51 message');
    }

    /**
    * Method Name: testBuildStrategyLowScoreCaution
    * @author: Naveen Kumar R
    * @description: Verifies the low-score (>=1) branch in You are currently
    *               and the CAUTION branch in Hard-stop alert.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testBuildStrategyLowScoreCaution() {
        List<DealOSSCalculationController.RowDTO> rows = makeRows(2);
        Test.startTest();
        DealOSSCalculationController.StrategyDTO s =
            DealOSSCalculationController.buildStrategy(rows, 30);
        Test.stopTest();
        System.assert(s.youAreCurrently.contains('weak early-stage'),
            'Expect >=1 message');
        System.assert(s.hardStopAlert.contains('CAUTION'),
            'Expect CAUTION hard stop');
    }

    /**
    * Method Name: testBuildStrategyAtRiskBudgetAuthority
    * @author: Naveen Kumar R
    * @description: Verifies the At Risk branches trigger when both budget
    *               (Q13) and decision-maker access (Q10) are low.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testBuildStrategyAtRiskBudgetAuthority() {
        List<DealOSSCalculationController.RowDTO> rows = makeRows(2);
        rows[12].score = 0; // Q13 budget low
        rows[9].score = 0;  // Q10 decision maker low
        Test.startTest();
        DealOSSCalculationController.StrategyDTO s =
            DealOSSCalculationController.buildStrategy(rows, 100);
        Test.stopTest();
        System.assert(s.youAreCurrently.contains('At risk'),
            'Expect at-risk message');
        System.assert(s.hardStopAlert.contains('STOP'),
            'Expect STOP hard stop');
        System.assert(s.strategyShift.contains('Pause commercial'),
            'Expect Pause commercial strategy shift');
    }

    /**
    * Method Name: testBuildStrategyMissingAllCategories
    * @author: Naveen Kumar R
    * @description: Verifies every Missing category appears when each
    *               relevant question is low.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testBuildStrategyMissingAllCategories() {
        List<DealOSSCalculationController.RowDTO> rows = makeRows(2);
        rows[0].score = 0;   // Q1 discovery
        rows[9].score = 0;   // Q10 authority
        rows[12].score = 0;  // Q13 budget
        rows[3].score = 0;   // Q4 urgency
        rows[8].score = 0;   // Q9 competitive
        Test.startTest();
        DealOSSCalculationController.StrategyDTO s =
            DealOSSCalculationController.buildStrategy(rows, 50);
        Test.stopTest();
        System.assert(s.missing.contains('Discovery'), 'Discovery gap expected');
        System.assert(s.missing.contains('Authority'), 'Authority gap expected');
        System.assert(s.missing.contains('Budget'), 'Budget gap expected');
        System.assert(s.missing.contains('Urgency'), 'Urgency gap expected');
        System.assert(s.missing.contains('Competitive'), 'Competitive gap expected');
    }

    /**
    * Method Name: testBuildStrategyEvaluationAtRisk
    * @author: Naveen Kumar R
    * @description: Verifies the At Risk branch triggered by engaged-at-
    *               evaluation (Q3) with weak decision process (Q11).
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testBuildStrategyEvaluationAtRisk() {
        List<DealOSSCalculationController.RowDTO> rows = makeRows(2);
        rows[2].yourAnswer = 'Evaluation';
        rows[10].score = 0; // Q11 weak
        Test.startTest();
        DealOSSCalculationController.StrategyDTO s =
            DealOSSCalculationController.buildStrategy(rows, 150);
        Test.stopTest();
        System.assert(s.youAreCurrently.contains('At risk'),
            'Expect at-risk via Evaluation path');
    }

    /**
    * Method Name: testBuildStrategyProposalNotSubmittedAtRisk
    * @author: Naveen Kumar R
    * @description: Verifies the At Risk branch triggered by Proposal yet to
    *               be submitted (Q14) with weak requirement clarity (Q1).
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testBuildStrategyProposalNotSubmittedAtRisk() {
        List<DealOSSCalculationController.RowDTO> rows = makeRows(2);
        rows[13].yourAnswer = 'Proposal yet to be submitted';
        rows[0].score = 0; // Q1 weak
        Test.startTest();
        DealOSSCalculationController.StrategyDTO s =
            DealOSSCalculationController.buildStrategy(rows, 180);
        Test.stopTest();
        System.assert(s.youAreCurrently.contains('At risk'),
            'Expect at-risk via Proposal path');
    }

    /**
    * Method Name: testBuildStrategyBudgetSoft
    * @author: Naveen Kumar R
    * @description: Verifies the Budget gap surfaces and the Next Best
    *               Action recommends validating budget when Q13 score is 1.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testBuildStrategyBudgetSoft() {
        List<DealOSSCalculationController.RowDTO> rows = makeRows(2);
        rows[12].score = 1; // Q13 soft budget
        Test.startTest();
        DealOSSCalculationController.StrategyDTO s =
            DealOSSCalculationController.buildStrategy(rows, 150);
        Test.stopTest();
        System.assert(s.missing.contains('Budget'), 'Budget gap expected');
        System.assert(s.nextBestAction.contains('Validate budget'),
            'Validate budget action expected');
    }

    /**
    * Method Name: testBuildRowNullRec
    * @author: Naveen Kumar R
    * @description: Verifies buildRow handles a null master record by
    *               setting a note rather than throwing.
    * @parameters: None
    * @return: void
    */
    @isTest
    static void testBuildRowNullRec() {
        DealOSSCalculationController.RowDTO row =
            DealOSSCalculationController.buildRow(1, 'Field__c', 'Answer', null, true);
        System.assertNotEquals(null, row.note, 'Should set a note when rec is null');
    }
}