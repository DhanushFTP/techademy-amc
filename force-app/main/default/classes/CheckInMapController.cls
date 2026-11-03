public with sharing class CheckInMapController {
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getCheckInsForParent(Id parentId) {
        if (parentId == null) {
            return new List<Map<String,Object>>();
        }

        // Determine 3-char prefix: 001 = Account, 005 = User
        String prefix = String.valueOf(parentId).substring(0,3);
        List<Check_In__c> recs;

        if (prefix == '005') {
            recs = [
                SELECT Check_In_Latitude__c, Check_In_Longitude__c,
                       Check_In_Time__c, Rep_Name__r.Name,
                       Check_Out_Time__c, Check_Out_Latitude__c,
                       Check_Out_Longitude__c, Check_Out_Notes__c, Status__c
                FROM Check_In__c
                WHERE Rep_Name__c = :parentId
                ORDER BY Check_In_Time__c DESC
            ];
        } else {
            recs = [
                SELECT Check_In_Latitude__c, Check_In_Longitude__c,
                       Check_In_Time__c, Rep_Name__r.Name,
                       Check_Out_Time__c, Check_Out_Latitude__c,
                       Check_Out_Longitude__c, Check_Out_Notes__c, Status__c
                FROM Check_In__c
                WHERE Account__c = :parentId
                ORDER BY Check_In_Time__c DESC
            ];
        }

        List<Map<String, Object>> markers = new List<Map<String, Object>>();
        for (Check_In__c c : recs) {
            String status = c.Status__c != null ? c.Status__c : 'Checked In';
            String descText = 'By ' + c.Rep_Name__r.Name + ' | ' + status;
            if (c.Check_Out_Time__c != null) {
                descText += ' | Out: ' + String.valueOf(c.Check_Out_Time__c);
            }

            // Check-in marker
            markers.add(new Map<String, Object>{
                'location'    => new Map<String, Object>{
                    'Latitude'  => c.Check_In_Latitude__c,
                    'Longitude' => c.Check_In_Longitude__c
                },
                'title'       => 'In: ' + String.valueOf(c.Check_In_Time__c),
                'description' => descText,
                'icon'        => 'standard:location'
            });

            // Check-out marker (if checked out and location is available)
            if (c.Check_Out_Latitude__c != null && c.Check_Out_Longitude__c != null) {
                String outDesc = 'By ' + c.Rep_Name__r.Name + ' | Check Out';
                if (String.isNotBlank(c.Check_Out_Notes__c)) {
                    outDesc += ' | ' + c.Check_Out_Notes__c;
                }
                markers.add(new Map<String, Object>{
                    'location'    => new Map<String, Object>{
                        'Latitude'  => c.Check_Out_Latitude__c,
                        'Longitude' => c.Check_Out_Longitude__c
                    },
                    'title'       => 'Out: ' + String.valueOf(c.Check_Out_Time__c),
                    'description' => outDesc,
                    'icon'        => 'standard:log_a_call'
                });
            }
        }
        return markers;
    }
}