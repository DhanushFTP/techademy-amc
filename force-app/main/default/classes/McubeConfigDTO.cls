/**
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 * Class Name      : McubeConfigDTO
 * Author          : Dhanush
 * Created Date    : May 5, 2026
 * Last Modified By: Dhanush
 * Last Modified On: May 5, 2026
 * Description     : This class implements for......
 *  
 * Change History  :
 *  Date          │   Author     │   Change
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 *  May 5, 2026  │ Dhanush   │ Initial version
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 */

public class McubeConfigDTO {
    @AuraEnabled public String callId;
    @AuraEnabled public String callType;
    @AuraEnabled public String relatedTo;
    @AuraEnabled public String recordUrl;
    @AuraEnabled public String agentNumber;
    @AuraEnabled public String callStatus;
    @AuraEnabled public String customerNumber;
    @AuraEnabled public String startTime;
    @AuraEnabled public String endTime;
    @AuraEnabled public String isCallback;   // "true"/"false"/"1"/blank — parsed to Boolean when stored
    @AuraEnabled public String callDuration;
    @AuraEnabled public String groupName;
    @AuraEnabled public String landingNumber;
    @AuraEnabled public String agentStatus;
    @AuraEnabled public String customStatus;
    @AuraEnabled public String dispositionStatus;
    @AuraEnabled public String dispositionComments;
    @AuraEnabled public String answeredDuration;
    @AuraEnabled public String agentName;
    @AuraEnabled public String disconnectedBy;

    public static List<String> getFieldNames() {
        Map<String, Object> m = (Map<String, Object>)
            JSON.deserializeUntyped(JSON.serialize(new McubeConfigDTO()));
        return new List<String>(m.keySet());
    }
}