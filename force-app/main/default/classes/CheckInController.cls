public with sharing class CheckInController {

    private static final Double MAX_DISTANCE_METERS = 500.0;
    private static final Double EARTH_RADIUS_METERS = 6371000.0;
    private static final String ERROR_POINT = 'Account Checkin';

    // ── Haversine distance (meters) ──
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

    // ── Helper to throw AuraHandledException with message properly set ──
    private static void throwAuraError(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        throw e;
    }

    // ── Write a log record for any check-in attempt (success or failure) ──
    private static void writeLog(Id accountId, Decimal latitude, Decimal longitude, String status, String errorMessage) {
        try {
            String msg = 'Account: ' + accountId
                       + ', Lat: '   + latitude
                       + ', Lon: '   + longitude
                       + ', User: '  + UserInfo.getName()
                       + ', Status: ' + status;
            if (String.isNotBlank(errorMessage)) {
                msg += ', Error: ' + errorMessage;
            }
            lcon__Error_Message_Handler__c log = new lcon__Error_Message_Handler__c(
                lcon__Error_Message__c = msg,
                lcon__Error_Point__c   = ERROR_POINT
            );
            Database.insert(log, false);
        } catch (Exception ignored) {}
    }

    // ── Validate proximity to Account location ──
    private static void validateProximity(Id accountId, Decimal latitude, Decimal longitude) {
        Account acc = [
            SELECT Account_Location__Latitude__s, Account_Location__Longitude__s
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];

        if (acc.Account_Location__Latitude__s == null || acc.Account_Location__Longitude__s == null) {
            throwAuraError('Account Location is not set. Please update the Account Location field on the account.');
        }

        Double distance = calculateDistance(
            latitude, longitude,
            acc.Account_Location__Latitude__s, acc.Account_Location__Longitude__s
        );

        if (distance > MAX_DISTANCE_METERS) {
            throwAuraError(
                'You must be within ' + MAX_DISTANCE_METERS.intValue() + ' meters of the account location. '
                + 'You are currently ' + distance.intValue() + ' meters away.'
            );
        }
    }

    // ── Check In (with proximity validation) ──
    @AuraEnabled
    public static Id createCheckIn(Id accountId, Decimal latitude, Decimal longitude) {
        try {
            validateProximity(accountId, latitude, longitude);

            Check_In__c rec = new Check_In__c(
                Account__c            = accountId,
                Check_In_Latitude__c  = latitude,
                Check_In_Longitude__c = longitude,
                Check_In_Time__c      = System.now(),
                Rep_Name__c           = UserInfo.getUserId(),
                Status__c             = 'Checked In'
            );
            insert rec;
            writeLog(accountId, latitude, longitude, 'Success', null);
            return rec.Id;
        } catch (AuraHandledException e) {
            writeLog(accountId, latitude, longitude, 'Failed', e.getMessage());
            throw e;
        } catch (Exception e) {
            writeLog(accountId, latitude, longitude, 'Failed', e.getMessage());
            throwAuraError(e.getMessage());
            return null;
        }
    }

    // ── Check Out (with proximity validation) ──
    @AuraEnabled
    public static void performCheckOut(Id checkInId, Decimal latitude, Decimal longitude, String notes) {
        Check_In__c rec = [
            SELECT Id, Account__c, Status__c
            FROM Check_In__c
            WHERE Id = :checkInId
            LIMIT 1
        ];

        try {
            if (rec.Status__c == 'Checked Out') {
                throwAuraError('This check-in has already been checked out.');
            }

            validateProximity(rec.Account__c, latitude, longitude);

            rec.Check_Out_Time__c      = System.now();
            rec.Check_Out_Latitude__c  = latitude;
            rec.Check_Out_Longitude__c = longitude;
            rec.Check_Out_Notes__c     = notes;
            rec.Status__c              = 'Checked Out';
            update rec;
            writeLog(rec.Account__c, latitude, longitude, 'Success', null);
        } catch (AuraHandledException e) {
            writeLog(rec.Account__c, latitude, longitude, 'Failed', e.getMessage());
            throw e;
        } catch (Exception e) {
            writeLog(rec.Account__c, latitude, longitude, 'Failed', e.getMessage());
            throwAuraError(e.getMessage());
        }
    }

    // ── Log a client-side error (e.g. GPS failure) from LWC ──
    @AuraEnabled
    public static void logClientError(Id accountId, String errorMessage) {
        writeLog(accountId, null, null, 'Failed', errorMessage);
    }

    // ── Get active (un-checked-out) check-in for current user + account ──
    @AuraEnabled
    public static Check_In__c getActiveCheckIn(Id accountId) {
        List<Check_In__c> recs = [
            SELECT Id, Check_In_Time__c, Check_In_Latitude__c, Check_In_Longitude__c
            FROM Check_In__c
            WHERE Account__c  = :accountId
              AND Rep_Name__c = :UserInfo.getUserId()
              AND Status__c   = 'Checked In'
            ORDER BY Check_In_Time__c DESC
            LIMIT 1
        ];
        return recs.isEmpty() ? null : recs[0];
    }
}