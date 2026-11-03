/******************************************************************
 * Class Name    : OSSScoreTrendController
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 22-05-2026
 * @description  : Visualforce controller extension that exposes the
 *                 Opportunity's OSS_Score_History__c JSON for the
 *                 OSSScoreTrendChart Chart.js page.
 * @author       : Naveen Kumar R
 * Used By       : - OSSScoreTrendChart Visualforce page
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Naveen Kumar R  | 22-05-2026 | Initial version
 * -----------------------------------------------------------------------------
 ******************************************************************/
public with sharing class OSSScoreTrendController {

    public String historyJson { get; set; }

    /**
    * Method Name: OSSScoreTrendController
    * @author: Naveen Kumar R
    * @description: Reads OSS_Score_History__c for the Opportunity bound
    *               to the standard controller and stores it in
    *               historyJson. Defaults to an empty array when the
    *               record Id is null or the field is blank.
    * @parameters:
    *     - ApexPages.StandardController stdController: Standard
    *       controller for Opportunity.
    * @return: instance
    */
    public OSSScoreTrendController(ApexPages.StandardController stdController) {
        this.historyJson = '[]';
        Id recordId = stdController.getId();
        if (recordId == null) {
            return;
        }
        try {
            Opportunity opp = [
                SELECT OSS_Score_History__c
                FROM Opportunity
                WHERE Id = :recordId
                LIMIT 1
            ];
            if (String.isNotBlank(opp.OSS_Score_History__c)) {
                this.historyJson = opp.OSS_Score_History__c;
            }
        } catch (Exception ignore) {
            // Leave historyJson as '[]'.
        }
    }
}