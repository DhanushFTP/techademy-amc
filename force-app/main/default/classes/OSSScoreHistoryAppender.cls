/******************************************************************
 * Class Name    : OSSScoreHistoryAppender
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 22-05-2026
 * @description  : Invocable Apex called from the Opportunity record-
 *                 triggered Flow that updates OSS_Last_Update_Date__c.
 *                 Appends an entry (date, user, score) to the JSON
 *                 stored on OSS_Score_History__c so the score trend
 *                 chart can render history over time.
 * @author       : Naveen Kumar R
 * Used By       : - Opportunity record-triggered Flow
 *                 - OSSScoreTrendChart Visualforce page (reads history)
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Naveen Kumar R  | 22-05-2026 | Initial version
 * -----------------------------------------------------------------------------
 ******************************************************************/
public with sharing class OSSScoreHistoryAppender {

    @TestVisible
    private static final Integer MAX_HISTORY = 50;

    public class HistoryInput {
        @InvocableVariable(required=true label='Opportunity Id'
            description='Opportunity Id whose history should be updated.')
        public Id opportunityId;

        @InvocableVariable(label='Score'
            description='Opportunity score to record. If left blank, the current Opportunity_Score__c is queried.')
        public Decimal score;
    }

    /**
    * Method Name: appendHistory
    * @author: Naveen Kumar R
    * @description: For each input, reads (or accepts) the current
    *               Opportunity_Score__c value and appends a new entry
    *               to OSS_Score_History__c. Older entries beyond
    *               MAX_HISTORY are dropped. Bulkified for the Flow.
    * @parameters:
    *     - List<HistoryInput> inputs: One per Opportunity to record.
    * @return: void
    */
    @InvocableMethod(
        label='Append OSS Score History'
        description='Adds a new entry to OSS_Score_History__c with today date, the running user, and the Opportunity score. Call from a record-triggered Flow on Opportunity.'
    )
    public static void appendHistory(List<HistoryInput> inputs) {
        if (inputs == null || inputs.isEmpty()) {
            return;
        }

        Map<Id, Decimal> providedScores = new Map<Id, Decimal>();
        Set<Id> allIds = new Set<Id>();
        for (HistoryInput inp : inputs) {
            if (inp == null || inp.opportunityId == null) {
                continue;
            }
            allIds.add(inp.opportunityId);
            if (inp.score != null) {
                providedScores.put(inp.opportunityId, inp.score);
            }
        }
        if (allIds.isEmpty()) {
            return;
        }

        Map<Id, Opportunity> oppsById = new Map<Id, Opportunity>([
            SELECT Id, Opportunity_Score__c, OSS_Score_History__c
            FROM Opportunity
            WHERE Id IN :allIds
        ]);

        String userName = UserInfo.getName();
        String today = String.valueOf(Date.today());
        List<Opportunity> toUpdate = new List<Opportunity>();

        for (Id oppId : allIds) {
            Opportunity opp = oppsById.get(oppId);
            if (opp == null) {
                continue;
            }
            Decimal score = providedScores.containsKey(oppId)
                ? providedScores.get(oppId)
                : opp.Opportunity_Score__c;

            List<Object> history = new List<Object>();
            if (String.isNotBlank(opp.OSS_Score_History__c)) {
                try {
                    history = (List<Object>) JSON.deserializeUntyped(opp.OSS_Score_History__c);
                } catch (Exception ignore) {
                    history = new List<Object>();
                }
            }
            history.add(new Map<String, Object>{
                'date' => today,
                'user' => userName,
                'score' => score
            });

            if (history.size() > MAX_HISTORY) {
                Integer excess = history.size() - MAX_HISTORY;
                List<Object> trimmed = new List<Object>();
                for (Integer i = excess; i < history.size(); i++) {
                    trimmed.add(history[i]);
                }
                history = trimmed;
            }

            toUpdate.add(new Opportunity(
                Id = oppId,
                OSS_Score_History__c = JSON.serialize(history)
            ));
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }
}