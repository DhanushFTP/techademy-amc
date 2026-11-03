/******************************************************************
 * Class Name    : DealOSSCalculationController
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 22-05-2026
 * @description  : Apex controller for the OSS Deal Calculation dashboard.
 *                 Loads the Opportunity answer fields and the Deal OSS
 *                 Calculation Master metadata, matches each answer to its
 *                 choice, and builds the dashboard rows and the Deal
 *                 Strategy Summary shown on the Opportunity record page.
 * @author       : Naveen Kumar R
 * Used By       : - dealOSSDashboard (LWC)
 *                 - DealOSSCalculationControllerTest
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Naveen Kumar R  | 22-05-2026 | Initial version
 * -----------------------------------------------------------------------------
 ******************************************************************/
public with sharing class DealOSSCalculationController {

    // === Question number (1-20) -> Opportunity answer field API name ===
    // If any API name below is wrong, fix it here and redeploy this class.
    @TestVisible
    private static final Map<Integer, String> QUESTION_FIELD = new Map<Integer, String>{
        1  => 'Requirements_RFQ__c',
        2  => 'Opportunity_Type__c',
        3  => 'Opportunity_Engaged_Stage__c',
        4  => 'Compelling_Need_to_Buy__c',
        5  => 'Customer_Requirement_Fulfilment__c',
        6  => 'Proposed_Solution_Accepted__c',
        7  => 'Customer_s_Business_Impact__c',
        8  => 'History_with_Customer__c',
        9  => 'Deal_Competitors__c',
        10 => 'Relation_with_Decision_Maker_Influence__c',
        11 => 'Understanding_of_formal_informal_DM__c',
        12 => 'Customer_evaluation_criteria__c',
        13 => 'Customer_budget__c',
        14 => 'Verbal_assurance_recieved__c',
        15 => 'Expected_day_of_closure__c',
        16 => 'Any_Dependency_risk__c',
        17 => 'Deal_size_comparison__c',
        18 => 'Future_business_potential__c',
        19 => 'Winning_other_customers__c',
        20 => 'Deal_timeline_confidence__c'
    };

    private static final String SCORE_FIELD = 'Opportunity_Score__c';
    private static final String LAST_UPDATE_FIELD = 'OSS_Last_Update_Date__c';
    private static final Integer DEFAULT_OUTDATED_THRESHOLD_DAYS = 7;
    private static final String DEFAULT_OUTDATED_REMARK =
        'OSS data is outdated. Please review and update the answers.';

    /**
    * Method Name: getDashboard
    * @author: Naveen Kumar R
    * @description: Builds the OSS dashboard for an Opportunity. Loads the
    *               metadata master, reads the Opportunity answer fields and
    *               score, and returns the rows plus the Deal Strategy Summary.
    * @parameters:
    *     - Id recordId: The Opportunity record Id whose dashboard is built.
    * @return: DashboardDTO - opportunity score, 20 question rows, and strategy.
    */
    @AuraEnabled(cacheable=true)
    public static DashboardDTO getDashboard(Id recordId) {
        try {
            // 1. Custom metadata -> Map<label, record>
            Map<String, Deal_OSS_Calculation_Master__mdt> masterByLabel =
                new Map<String, Deal_OSS_Calculation_Master__mdt>();
            for (Deal_OSS_Calculation_Master__mdt m : queryMaster()) {
                masterByLabel.put(m.MasterLabel, m);
            }

            // 2. Keep only field names that really exist on Opportunity
            Map<String, Schema.SObjectField> oppFields =
                Schema.SObjectType.Opportunity.fields.getMap();
            List<String> validFields = new List<String>();
            for (String f : QUESTION_FIELD.values()) {
                if (oppFields.containsKey(f.toLowerCase())) {
                    validFields.add(f);
                }
            }

            // 3. Query the Opportunity record (answer fields + score + last update)
            Boolean hasScoreField = oppFields.containsKey(SCORE_FIELD.toLowerCase());
            Boolean hasLastUpdateField = oppFields.containsKey(LAST_UPDATE_FIELD.toLowerCase());
            Set<String> queryFields = new Set<String>(validFields);
            if (hasScoreField) {
                queryFields.add(SCORE_FIELD);
            }
            if (hasLastUpdateField) {
                queryFields.add(LAST_UPDATE_FIELD);
            }
            // Standard field - used to suppress the outdated flag on closed deals.
            queryFields.add('IsClosed');

            Opportunity opp;
            if (recordId != null && !queryFields.isEmpty()) {
                String soql = 'SELECT Id, ' + String.join(new List<String>(queryFields), ', ')
                            + ' FROM Opportunity WHERE Id = :recordId LIMIT 1';
                List<Opportunity> opps = (List<Opportunity>) Database.query(soql);
                if (!opps.isEmpty()) {
                    opp = opps[0];
                }
            }

            // 4. Build the dashboard
            DashboardDTO dto = new DashboardDTO();
            if (opp != null && hasScoreField) {
                dto.opportunityScore = (Decimal) opp.get(SCORE_FIELD);
            }
            applyOutdatedCheck(dto, opp, hasLastUpdateField);
            dto.rows = new List<RowDTO>();
            for (Integer i = 1; i <= 20; i++) {
                String fieldName = QUESTION_FIELD.get(i);
                Boolean fieldExists = oppFields.containsKey(fieldName.toLowerCase());
                String answer;
                if (opp != null && fieldExists) {
                    Object v = opp.get(fieldName);
                    answer = (v == null) ? null : String.valueOf(v);
                }
                dto.rows.add(buildRow(i, fieldName, answer, masterByLabel.get(String.valueOf(i)), fieldExists));
            }
            dto.strategy = buildStrategy(dto.rows, dto.opportunityScore);
            return dto;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
    * Method Name: queryMaster
    * @author: Naveen Kumar R
    * @description: Queries every Deal OSS Calculation Master metadata record
    *               with all question and choice fields.
    * @parameters: None
    * @return: List<Deal_OSS_Calculation_Master__mdt> - all master records.
    */
    private static List<Deal_OSS_Calculation_Master__mdt> queryMaster() {
        return [
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
        ];
    }

    /**
    * Method Name: applyOutdatedCheck
    * @author: Naveen Kumar R
    * @description: Reads the OSS_Outdated_Threshold_Days and
    *               OSS_Outdated_Remark Custom Labels, compares the
    *               Opportunity's OSS_Last_Update_Date__c to today, and
    *               sets isOutdated and outdatedRemark on the dashboard
    *               when the data is older than the threshold or has never
    *               been updated. Closed opportunities (IsClosed = true)
    *               never show as outdated regardless of last-update age.
    * @parameters:
    *     - DashboardDTO dto: The dashboard to populate.
    *     - Opportunity opp: The Opportunity record (may be null).
    *     - Boolean hasLastUpdateField: Whether OSS_Last_Update_Date__c
    *       exists on Opportunity.
    * @return: void
    */
    @TestVisible
    private static void applyOutdatedCheck(DashboardDTO dto, Opportunity opp, Boolean hasLastUpdateField) {
        Integer threshold = DEFAULT_OUTDATED_THRESHOLD_DAYS;
        String remark = DEFAULT_OUTDATED_REMARK;
        try {
            String thresholdLabel = System.Label.OSS_Outdated_Threshold_Days;
            if (String.isNotBlank(thresholdLabel)) {
                threshold = Integer.valueOf(thresholdLabel.trim());
            }
        } catch (Exception ignore) {
            // Label missing or not a valid integer; keep the default.
        }
        String remarkLabel = System.Label.OSS_Outdated_Remark;
        if (String.isNotBlank(remarkLabel)) {
            remark = remarkLabel;
        }

        Date lastUpdate;
        if (opp != null && hasLastUpdateField) {
            Object v = opp.get(LAST_UPDATE_FIELD);
            if (v instanceof Date) {
                lastUpdate = (Date) v;
            } else if (v instanceof Datetime) {
                lastUpdate = ((Datetime) v).date();
            }
        }

        if (lastUpdate == null) {
            dto.isOutdated = true;
        } else {
            Integer days = lastUpdate.daysBetween(Date.today());
            dto.isOutdated = days > threshold;
        }
        // Closed opportunities never show as outdated.
        if (opp != null && opp.IsClosed == true) {
            dto.isOutdated = false;
        }
        if (dto.isOutdated == true) {
            dto.outdatedRemark = remark;
        }
    }

    /**
    * Method Name: buildRow
    * @author: Naveen Kumar R
    * @description: Builds a single dashboard row for one question by matching
    *               the rep's answer to its choice and pulling the score and
    *               coaching content. Sets a note when the field or answer is
    *               not found.
    * @parameters:
    *     - Integer slNo: The question number (1-20).
    *     - String fieldName: The Opportunity answer field API name.
    *     - String answer: The answer value selected on the Opportunity.
    *     - Deal_OSS_Calculation_Master__mdt rec: The matching master record.
    *     - Boolean fieldExists: Whether the field exists on Opportunity.
    * @return: RowDTO - the populated dashboard row.
    */
    @TestVisible
    private static RowDTO buildRow(Integer slNo, String fieldName, String answer,
                                   Deal_OSS_Calculation_Master__mdt rec, Boolean fieldExists) {
        RowDTO row = new RowDTO();
        row.slNo = slNo;
        row.question = (rec != null) ? rec.Question__c : null;
        row.yourAnswer = answer;

        if (!fieldExists) {
            row.note = 'Opportunity field not found: ' + fieldName;
            return row;
        }
        if (rec == null) {
            row.note = 'No master record for question ' + slNo;
            return row;
        }
        if (String.isBlank(answer)) {
            return row; // not answered yet
        }

        String letter = matchChoice(rec, answer);
        if (letter == null) {
            row.note = 'Answer not found in master options: ' + answer;
            return row;
        }
        row.score = (Decimal) rec.get('Choice_' + letter + '_Score__c');
        row.recommendation = (String) rec.get('Choice_' + letter + '_Recommendation__c');
        row.talkTrack = (String) rec.get('Choice_' + letter + '_Talk_Track__c');
        row.riskFlag = (String) rec.get('Choice_' + letter + '_Risk_Flag__c');
        row.actionPlan = (String) rec.get('Choice_' + letter + '_Action_Plan__c');
        row.likelyObjection = (String) rec.get('Choice_' + letter + '_Likely_Objection_Response__c');
        return row;
    }

    /**
    * Method Name: matchChoice
    * @author: Naveen Kumar R
    * @description: Finds which choice (A, B, C or D) on the master record
    *               matches the given answer value.
    * @parameters:
    *     - Deal_OSS_Calculation_Master__mdt rec: The master record.
    *     - String answer: The answer value to match.
    * @return: String - 'A', 'B', 'C', 'D', or null when no match is found.
    */
    private static String matchChoice(Deal_OSS_Calculation_Master__mdt rec, String answer) {
        String a = norm(answer);
        if (a == norm(rec.Choice_A__c)) { return 'A'; }
        if (a == norm(rec.Choice_B__c)) { return 'B'; }
        if (a == norm(rec.Choice_C__c)) { return 'C'; }
        if (a == norm(rec.Choice_D__c)) { return 'D'; }
        return null;
    }

    /**
    * Method Name: norm
    * @author: Naveen Kumar R
    * @description: Normalises a string for comparison by trimming, lower-
    *               casing, and straightening curly apostrophes.
    * @parameters:
    *     - String s: The value to normalise.
    * @return: String - the normalised value (empty string when null).
    */
    private static String norm(String s) {
        if (s == null) { return ''; }
        return s.trim().toLowerCase()
                .replace('’', '\'')
                .replace('‘', '\'');
    }

    /**
    * Method Name: qScore
    * @author: Naveen Kumar R
    * @description: Returns the score of a given question from the row list,
    *               treating a missing or unanswered question as -1.
    * @parameters:
    *     - List<RowDTO> rows: The dashboard rows.
    *     - Integer q: The question number (1-20).
    * @return: Decimal - the question score, or -1 when not available.
    */
    private static Decimal qScore(List<RowDTO> rows, Integer q) {
        if (q < 1 || q > rows.size()) {
            return -1;
        }
        Decimal sc = rows[q - 1].score;
        return (sc == null) ? -1 : sc;
    }

    /**
    * Method Name: qLow
    * @author: Naveen Kumar R
    * @description: Indicates whether a question is a qualification gap, i.e.
    *               its score is zero or below.
    * @parameters:
    *     - List<RowDTO> rows: The dashboard rows.
    *     - Integer q: The question number (1-20).
    * @return: Boolean - true when the question score is <= 0.
    */
    private static Boolean qLow(List<RowDTO> rows, Integer q) {
        return qScore(rows, q) <= 0;
    }

    /**
    * Method Name: qAnswer
    * @author: Naveen Kumar R
    * @description: Returns the answer value of a given question from the
    *               row list.
    * @parameters:
    *     - List<RowDTO> rows: The dashboard rows.
    *     - Integer q: The question number (1-20).
    * @return: String - the answer value, or null when not available.
    */
    private static String qAnswer(List<RowDTO> rows, Integer q) {
        if (q < 1 || q > rows.size()) {
            return null;
        }
        return rows[q - 1].yourAnswer;
    }

    /**
    * Method Name: buildStrategy
    * @author: Naveen Kumar R
    * @description: Builds the Deal Strategy Summary (You are currently,
    *               Missing, Strategy shift, Next best action, Top performer
    *               benchmark, Hard-stop alert) from the question scores and
    *               the opportunity score.
    * @parameters:
    *     - List<RowDTO> rows: The 20 dashboard rows with scores.
    *     - Decimal score: The total Opportunity score.
    * @return: StrategyDTO - the six coaching summary values.
    */
    @TestVisible
    private static StrategyDTO buildStrategy(List<RowDTO> rows, Decimal score) {
        StrategyDTO s = new StrategyDTO();
        Decimal total = (score == null) ? 0 : score;

        Boolean d14 = qLow(rows, 1);
        Boolean d17 = qLow(rows, 4);
        Boolean d22 = qLow(rows, 9);
        Boolean d23 = qLow(rows, 10);
        Boolean d24 = qLow(rows, 11);
        Boolean d25 = qLow(rows, 12);
        Boolean d26le0 = qScore(rows, 13) <= 0;
        Boolean d26le1 = qScore(rows, 13) <= 1;
        Boolean d28 = qLow(rows, 15);
        Boolean c16eval = qAnswer(rows, 3) == 'Evaluation';
        Boolean c27prop = qAnswer(rows, 14) == 'Proposal yet to be submitted';

        Boolean atRisk =
            (d26le0 && d23) ||
            (d26le0 && d24) ||
            (c27prop && (d14 || d25)) ||
            (c16eval && (d23 || d24));

        if (atRisk) {
            s.youAreCurrently = 'At risk. You are progressing a deal with a major qualification gap.';
        } else if (total >= 151) {
            s.youAreCurrently = 'Running a qualified deal with momentum. Stay in control and keep the close path tight.';
        } else if (total >= 101) {
            s.youAreCurrently = 'Working a promising deal, but gaps still need active control.';
        } else if (total >= 51) {
            s.youAreCurrently = 'Working an interested but under-qualified deal. You are still closer to discovery than closure.';
        } else if (total >= 1) {
            s.youAreCurrently = 'Working a weak early-stage deal that needs re-qualification before more effort.';
        } else {
            s.youAreCurrently = 'Working an unqualified deal. Rebuild from scratch or step away.';
        }

        String m = '';
        if (d14 || d25) { m += 'Discovery / Criteria, '; }
        if (d23 || d24) { m += 'Authority / Process, '; }
        if (d26le1) { m += 'Budget, '; }
        if (d17 || d28) { m += 'Urgency / Timeline, '; }
        if (d22) { m += 'Competitive plan, '; }
        m = m.trim();
        s.missing = (m == '') ? 'None' : m.removeEnd(',');

        if ((d26le0 && d23) || (d26le0 && d24)) {
            s.strategyShift = 'Pause commercial progression and rebuild buyer access plus budget direction before moving further.';
        } else if (d14 || d25) {
            s.strategyShift = 'Move back to discovery. Rebuild the problem, evaluation criteria, and success outcome before demo or proposal.';
        } else if (d23 || d24) {
            s.strategyShift = 'Get direct buyer access and map the real decision path before you push commercials.';
        } else if (d26le0) {
            s.strategyShift = 'Do not sell the full answer yet. Build a phase-one case or surface a realistic budget range first.';
        } else if (d17 || d28) {
            s.strategyShift = 'Create urgency by quantifying the cost of delay and tying the deal to a real timeline.';
        } else if (total >= 151) {
            s.strategyShift = 'Stay consultative, keep decision-maker access active, and drive dated next steps to closure.';
        } else if (total >= 101) {
            s.strategyShift = 'Tighten the weak areas now so the deal can move from probable to commit.';
        } else if (total >= 51) {
            s.strategyShift = 'Slow down, qualify harder, and earn the right to progress this deal.';
        } else {
            s.strategyShift = 'Re-qualify completely before investing more time.';
        }

        if (d23 || d24) {
            s.nextBestAction = 'Get the decision maker and the real approval path into the next conversation before you progress.';
        } else if (d26le1) {
            s.nextBestAction = 'Validate budget range, budget owner, and approval status in the next conversation.';
        } else if (d14 || d25) {
            s.nextBestAction = 'Run a focused discovery call and close the requirement plus evaluation gaps before solutioning.';
        } else if (d17 || d28) {
            s.nextBestAction = 'Find the trigger for action and agree a buyer timeline before proposal.';
        } else if (total >= 151) {
            s.nextBestAction = 'Convert the current momentum into a dated close plan with owners and deadlines.';
        } else if (total >= 101) {
            s.nextBestAction = 'Fix the single biggest gap in the next interaction before pushing the deal further.';
        } else if (total >= 51) {
            s.nextBestAction = 'Re-qualify the deal before the next demo, proposal, or commercial discussion.';
        } else {
            s.nextBestAction = 'Step back and confirm whether this is a real deal worth pursuing now.';
        }

        if (total <= 0 || atRisk) {
            s.topPerformerBenchmark = 'A top performer would stop pushing and would first repair the qualification gap before spending more credibility on this deal.';
        } else if (total >= 151) {
            s.topPerformerBenchmark = 'A top performer would keep the relationship warm, lock dates and owners, and protect value instead of relaxing early.';
        } else if (total >= 101) {
            s.topPerformerBenchmark = 'A top performer would not confuse promise with control. They would fix the weak area now.';
        } else if (total >= 51) {
            s.topPerformerBenchmark = 'A top performer would reopen discovery instead of hoping the current pitch lands.';
        } else {
            s.topPerformerBenchmark = 'A top performer would politely step back, re-qualify, and avoid over-investing in a weak deal.';
        }

        if (total <= 0 || atRisk) {
            s.hardStopAlert = 'STOP. You are about to lose control of this deal. Do not move to proposal or price negotiation until you fix the missing buyer, budget, or discovery gap.';
        } else if (total <= 50) {
            s.hardStopAlert = 'CAUTION. The deal score is too weak for confident progression. Re-qualify before investing more effort.';
        } else {
            s.hardStopAlert = 'No hard-stop trigger right now. Keep tightening the deal instead of coasting.';
        }

        return s;
    }

    public class DashboardDTO {
        @AuraEnabled public Decimal opportunityScore;
        @AuraEnabled public Boolean isOutdated;
        @AuraEnabled public String outdatedRemark;
        @AuraEnabled public List<RowDTO> rows;
        @AuraEnabled public StrategyDTO strategy;
    }

    public class StrategyDTO {
        @AuraEnabled public String youAreCurrently;
        @AuraEnabled public String missing;
        @AuraEnabled public String strategyShift;
        @AuraEnabled public String nextBestAction;
        @AuraEnabled public String topPerformerBenchmark;
        @AuraEnabled public String hardStopAlert;
    }

    public class RowDTO {
        @AuraEnabled public Integer slNo;
        @AuraEnabled public String question;
        @AuraEnabled public String yourAnswer;
        @AuraEnabled public Decimal score;
        @AuraEnabled public String recommendation;
        @AuraEnabled public String talkTrack;
        @AuraEnabled public String riskFlag;
        @AuraEnabled public String actionPlan;
        @AuraEnabled public String likelyObjection;
        @AuraEnabled public String note;
    }
}