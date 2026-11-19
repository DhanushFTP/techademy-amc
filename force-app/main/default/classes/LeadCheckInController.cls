/******************************************************************
 * Class Name    : LeadCheckInController
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 06-11-2026
 * @description  : Check In / Check Out on Leads with phone GPS. The Lead
 *                 version of CheckInController (Accounts).
 *
 *                 Same rules as the Account check-in:
 *                   - check-in and check-out only within the check-in
 *                     distance of the lead's Lead Geo Location
 *                     (Lead_Geo_Location__c, captured with the Capture
 *                     Location action)
 *                   - one Lead_Check_In__c per visit; Rep Name and owner =
 *                     the rep; Status Checked In -> Checked Out
 *                 One difference: failures are returned in a CheckInResult
 *                 instead of being thrown, so the log row written for a
 *                 failed attempt is kept. Every attempt is logged to
 *                 lcon__Error_Message_Handler__c with Error Point
 *                 'Lead Checkin'.
 *
 *                 getMapMarkers builds the map for the Lead page;
 *                 CheckInMapController calls it for Lead Ids, so the same
 *                 checkInMap component works on the Lead page.
 *
 *                 Config (custom label):
 *                   Check_In_Max_Distance_Meters -> max distance in
 *                       meters for Check In and Check Out (Account and
 *                       Lead). 1000 m is used if the label is blank, zero
 *                       or not a number.
 * @author       : Tharun N
 * @group        : Lead
 * Used By       : - leadCheckInLocation LWC (Lead "Check In" action,
 *                   through leadCheckInWrapper)
 *                 - CheckInMapController (map markers for Lead Ids)
 * Test Class    : LeadCheckInControllerTest
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Tharun N        | 06-11-2026 | Initial version (500 m check-in
 *     |                 |            | distance)
 * 1.1 | Tharun N        | 16-11-2026 | Check-in distance raised from 500 m
 *     |                 |            | to 1000 m and moved to the custom
 *     |                 |            | label Check_In_Max_Distance_Meters
 *     |                 |            | (maxDistanceMeters), shared with the
 *     |                 |            | Account check-in. Standard header.
 * -----------------------------------------------------------------------------
 ******************************************************************/
public with sharing class LeadCheckInController {

    // Used when the Check_In_Max_Distance_Meters label is blank, zero or not a number
    private static final Double DEFAULT_MAX_DISTANCE_METERS = 1000.0;
    private static final Double EARTH_RADIUS_METERS = 6371000.0;
    private static final String ERROR_POINT = 'Lead Checkin';
    private static final String STATUS_CHECKED_IN = 'Checked In';
    private static final String STATUS_CHECKED_OUT = 'Checked Out';

    /**
     * @description Outcome of a check-in or check-out attempt.
     */
    public class CheckInResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public Id checkInId;
    }

    // A rule that stops the check-in or check-out; its message is shown to the rep
    private class LeadCheckInException extends Exception {}

    /**
     * @description Checks the rep in at a lead, if they are within the check-in distance
     *              (Check_In_Max_Distance_Meters) of its Lead Geo Location.
     * @param leadId    Lead the rep is checking in at
     * @param latitude  Latitude reported by the phone
     * @param longitude Longitude reported by the phone
     * @return CheckInResult with success, message and the new Lead_Check_In__c Id
     */
    @AuraEnabled
    public static CheckInResult checkIn(Id leadId, Decimal latitude, Decimal longitude) {
        CheckInResult result = new CheckInResult();
        try {
            validateProximity(leadId, latitude, longitude);

            Lead_Check_In__c rec = new Lead_Check_In__c(
                Lead__c               = leadId,
                Check_In_Latitude__c  = latitude,
                Check_In_Longitude__c = longitude,
                Check_In_Time__c      = System.now(),
                Rep_Name__c           = UserInfo.getUserId(),
                Status__c             = STATUS_CHECKED_IN
            );
            insert rec;
            result.success = true;
            result.checkInId = rec.Id;
            result.message = 'Your check-in has been recorded.';
        } catch (DmlException e) {
            result.success = false;
            result.message = e.getDmlMessage(0);
        } catch (Exception e) {
            result.success = false;
            result.message = e.getMessage();
        }
        writeLog(leadId, latitude, longitude, result);
        return result;
    }

    /**
     * @description Checks the rep out of an open lead check-in, if they are within the check-in
     *              distance (Check_In_Max_Distance_Meters) of the lead's Lead Geo Location.
     * @param checkInId Lead_Check_In__c to close
     * @param latitude  Latitude reported by the phone
     * @param longitude Longitude reported by the phone
     * @param notes     Optional visit notes
     * @return CheckInResult with success and message
     */
    @AuraEnabled
    public static CheckInResult checkOut(Id checkInId, Decimal latitude, Decimal longitude, String notes) {
        CheckInResult result = new CheckInResult();
        result.checkInId = checkInId;
        Id leadId;
        try {
            List<Lead_Check_In__c> recs = [
                SELECT Id, Lead__c, Status__c
                FROM Lead_Check_In__c
                WHERE Id = :checkInId
                LIMIT 1
            ];
            if (recs.isEmpty()) {
                throw new LeadCheckInException('This check-in was not found.');
            }
            Lead_Check_In__c rec = recs[0];
            leadId = rec.Lead__c;

            if (rec.Status__c == STATUS_CHECKED_OUT) {
                throw new LeadCheckInException('This check-in has already been checked out.');
            }
            if (leadId == null) {
                throw new LeadCheckInException('The lead of this check-in no longer exists.');
            }

            validateProximity(leadId, latitude, longitude);

            rec.Check_Out_Time__c      = System.now();
            rec.Check_Out_Latitude__c  = latitude;
            rec.Check_Out_Longitude__c = longitude;
            rec.Check_Out_Notes__c     = notes;
            rec.Status__c              = STATUS_CHECKED_OUT;
            update rec;
            result.success = true;
            result.message = 'Your check-out has been recorded.';
        } catch (DmlException e) {
            result.success = false;
            result.message = e.getDmlMessage(0);
        } catch (Exception e) {
            result.success = false;
            result.message = e.getMessage();
        }
        writeLog(leadId != null ? leadId : checkInId, latitude, longitude, result);
        return result;
    }

    /**
     * @description The rep's open (not checked-out) check-in on this lead, or null.
     * @param leadId Lead the component is on
     * @return Lead_Check_In__c or null
     */
    @AuraEnabled
    public static Lead_Check_In__c getActiveCheckIn(Id leadId) {
        Id userId = UserInfo.getUserId();
        List<Lead_Check_In__c> recs = [
            SELECT Id, Check_In_Time__c, Check_In_Latitude__c, Check_In_Longitude__c
            FROM Lead_Check_In__c
            WHERE Lead__c     = :leadId
              AND Rep_Name__c = :userId
              AND Status__c   = :STATUS_CHECKED_IN
            ORDER BY Check_In_Time__c DESC
            LIMIT 1
        ];
        return recs.isEmpty() ? null : recs[0];
    }

    /**
     * @description Logs an error from the phone (for example GPS off or permission denied).
     * @param leadId       Lead the component is on
     * @param errorMessage Message shown to the rep
     */
    @AuraEnabled
    public static void logClientError(Id leadId, String errorMessage) {
        CheckInResult result = new CheckInResult();
        result.success = false;
        result.message = errorMessage;
        writeLog(leadId, null, null, result);
    }

    /**
     * @description Map markers (check-in and check-out points) for one lead. Called by
     *              CheckInMapController.getCheckInsForParent for Lead Ids; same marker format as
     *              the Account map.
     * @param leadId Lead the map is on
     * @return list of marker maps (location, title, description, icon)
     */
    public static List<Map<String, Object>> getMapMarkers(Id leadId) {
        List<Map<String, Object>> markers = new List<Map<String, Object>>();
        for (Lead_Check_In__c c : [
            SELECT Check_In_Latitude__c, Check_In_Longitude__c,
                   Check_In_Time__c, Rep_Name__r.Name,
                   Check_Out_Time__c, Check_Out_Latitude__c,
                   Check_Out_Longitude__c, Check_Out_Notes__c, Status__c
            FROM Lead_Check_In__c
            WHERE Lead__c = :leadId
            ORDER BY Check_In_Time__c DESC
        ]) {
            String status = c.Status__c != null ? c.Status__c : STATUS_CHECKED_IN;
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

    // ── Rules ──

    // Stops the visit unless the rep is within the check-in distance of the lead's saved location
    private static void validateProximity(Id leadId, Decimal latitude, Decimal longitude) {
        if (leadId == null || leadId.getSObjectType() != Lead.SObjectType) {
            throw new LeadCheckInException('This check-in works only on Leads.');
        }
        if (latitude == null || longitude == null) {
            throw new LeadCheckInException('The phone did not return a location. Please try again.');
        }

        List<Lead> leads = [
            SELECT Lead_Geo_Location__Latitude__s, Lead_Geo_Location__Longitude__s
            FROM Lead
            WHERE Id = :leadId
            LIMIT 1
        ];
        if (leads.isEmpty()) {
            throw new LeadCheckInException('Lead not found or you do not have access to it.');
        }
        Decimal savedLat = leads[0].Lead_Geo_Location__Latitude__s;
        Decimal savedLng = leads[0].Lead_Geo_Location__Longitude__s;
        if (savedLat == null || savedLng == null) {
            throw new LeadCheckInException(
                'Lead Geo Location is not set. Capture it first with Capture Location on this lead.');
        }

        Double distance = calculateDistance(latitude, longitude, savedLat, savedLng);
        Double maxDistance = maxDistanceMeters();
        if (distance > maxDistance) {
            throw new LeadCheckInException(
                'You must be within ' + maxDistance.intValue() + ' meters of the lead location. '
                + 'You are currently ' + distance.intValue() + ' meters away.'
            );
        }
    }

    /**
    * Method Name: maxDistanceMeters
    * @author: Tharun N
    * @description: Max distance allowed between the rep's phone and the
    *               Lead Geo Location for Check In and Check Out, from the
    *               custom label Check_In_Max_Distance_Meters (shared with
    *               the Account check-in). Falls back to 1000 m when the
    *               label is blank, zero or not a number.
    * @parameters: None
    * @return: Double distance in meters.
    */
    @TestVisible
    private static Double maxDistanceMeters() {
        try {
            Double value = Double.valueOf(System.Label.Check_In_Max_Distance_Meters.trim());
            return value > 0 ? value : DEFAULT_MAX_DISTANCE_METERS;
        } catch (Exception e) {
            return DEFAULT_MAX_DISTANCE_METERS;
        }
    }

    // ── Haversine distance (meters), same formula as the Account check-in ──
    private static Double calculateDistance(Decimal lat1, Decimal lon1, Decimal lat2, Decimal lon2) {
        Double dLat = toRadians((Double)(lat2 - lat1));
        Double dLon = toRadians((Double)(lon2 - lon1));
        Double rLat1 = toRadians((Double)lat1);
        Double rLat2 = toRadians((Double)lat2);

        Double a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
                 + Math.cos(rLat1) * Math.cos(rLat2)
                 * Math.sin(dLon / 2) * Math.sin(dLon / 2);
        Double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return EARTH_RADIUS_METERS * c;
    }

    private static Double toRadians(Double degrees) {
        return degrees * Math.PI / 180;
    }

    // ── Log every attempt (success or failure); logging never blocks the check-in ──
    private static void writeLog(Id recordId, Decimal latitude, Decimal longitude, CheckInResult result) {
        try {
            String msg = 'Lead: ' + recordId
                       + ', Lat: '    + latitude
                       + ', Lon: '    + longitude
                       + ', User: '   + UserInfo.getName()
                       + ', Status: ' + (result.success == true ? 'Success' : 'Failed');
            if (result.success != true && String.isNotBlank(result.message)) {
                msg += ', Error: ' + result.message;
            }
            Database.insert(new lcon__Error_Message_Handler__c(
                lcon__Error_Message__c = msg,
                lcon__Error_Point__c   = ERROR_POINT
            ), false);
        } catch (Exception ignored) {}
    }
}