/******************************************************************
 * Class Name    : AccountLocationController
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 04-11-2026
 * @description  : Captures a rep's phone location into one record's
 *                 location field. One controller serves both objects:
 *                   Account -> Account_Location__c
 *                   Lead    -> Lead_Geo_Location__c
 *                 Each object has its own Override Location checkbox
 *                 (Location_Override__c).
 *
 *                 A location can be captured when:
 *                   1. the record has no location yet, or
 *                   2. Override Location is ticked on the record. It is
 *                      ticked by a System Administrator or a user with
 *                      the Account_Location_Override permission set, and
 *                      it is unticked in the same save, so each tick
 *                      allows one update.
 *                 Otherwise the rep is shown who to ask
 *                 (Account_Location_Locked_Message /
 *                 Lead_Location_Locked_Message).
 *
 *                 Only the record passed in is updated. The update runs
 *                 without sharing so a rep can capture the location of a
 *                 record they can see but not edit; the rules above are
 *                 always checked here first, whatever the component
 *                 shows. Every save attempt is logged to
 *                 lcon__Error_Message_Handler__c (Error Point
 *                 'Account Location Update' or 'Lead Location Update').
 *                 Failed saves return a message instead of throwing, so
 *                 their log rows are kept.
 *
 *                 Config (custom labels):
 *                   Account_Location_Max_Accuracy_Meters -> worst GPS
 *                       accuracy accepted, in meters (Account and Lead)
 *                   Account_Location_Locked_Message -> message shown
 *                       when an account location is locked
 *                   Lead_Location_Locked_Message -> message shown when a
 *                       lead location is locked
 *
 *                 The Account_Location_Locked and Lead_Location_Locked
 *                 validation rules apply the same lock to manual edits.
 * @author       : Tharun N
 * @group        : Account
 * Used By       : - accountLocationCapture LWC: card on the Account
 *                   record page and on the Lead record page
 *                 - locationCaptureWrapper Aura: Lead "Capture Location"
 *                   quick action (phone, OneMerge Lead page)
 * Test Class    : AccountLocationControllerTest
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Tharun N        | 04-11-2026 | Initial version: Account location
 *     |                 |            | capture into Account_Location__c,
 *     |                 |            | one-time Override Location, GPS
 *     |                 |            | accuracy limit, locked message and
 *     |                 |            | 'Account Location Update' log.
 * 1.1 | Tharun N        | 06-11-2026 | Lead support: saves Lead_Geo_Location__c
 *     |                 |            | on Leads with the Lead Override
 *     |                 |            | Location, Lead_Location_Locked_Message
 *     |                 |            | and 'Lead Location Update' log point.
 *     |                 |            | Parameter accountId renamed recordId;
 *     |                 |            | LocationState.objectLabel added for
 *     |                 |            | the card title; typed Account / Lead
 *     |                 |            | reads and updates (LocationWriter).
 * 1.2 | Tharun N        | 11-11-2026 | Standard header, change log and
 *     |                 |            | method comments added. No code change.
 * -----------------------------------------------------------------------------
 ******************************************************************/
public with sharing class AccountLocationController {

    private static final String ACCOUNT_LOG_POINT = 'Account Location Update';
    private static final String LEAD_LOG_POINT = 'Lead Location Update';
    private static final Decimal DEFAULT_MAX_ACCURACY_METERS = 100;
    private static final String WRONG_RECORD_MESSAGE = 'Open this from an Account or Lead record.';

    /**
     * @description Location details of a record, shown by the component.
     */
    public class LocationState {
        @AuraEnabled public String objectLabel;
        @AuraEnabled public Boolean hasLocation;
        @AuraEnabled public Decimal latitude;
        @AuraEnabled public Decimal longitude;
        @AuraEnabled public Boolean overrideAllowed;
        @AuraEnabled public Boolean canCapture;
        @AuraEnabled public String lockedMessage;
        @AuraEnabled public Decimal maxAccuracyMeters;
    }

    /**
     * @description Outcome of a save attempt.
     */
    public class SaveResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;

        SaveResult(Boolean success, String message) {
            this.success = success;
            this.message = message;
        }
    }

    /**
    * Method Name: getLocationState
    * @author: Tharun N
    * @description: Returns the record's saved location and whether the
    *               rep may capture it now. Called by the component when
    *               it loads and again after each save.
    * @parameters:
    *     - Id recordId: The Account or Lead the component is on.
    * @return: LocationState for the record. Throws AuraHandledException
    *          when the Id is not an Account or Lead, or the rep cannot
    *          see the record.
    */
    @AuraEnabled
    public static LocationState getLocationState(Id recordId) {
        if (!isSupported(recordId)) {
            throw newAuraError(WRONG_RECORD_MESSAGE);
        }
        SObject rec = readRecord(recordId);
        if (rec == null) {
            throw newAuraError(notFoundMessage(recordId));
        }
        return buildState(recordId, rec);
    }

    /**
    * Method Name: saveLocation
    * @author: Tharun N
    * @description: Saves the rep's current position as the record's
    *               location, when allowed, and unticks Override Location
    *               in the same update. The rules are checked here even if
    *               the component already checked them. Every attempt is
    *               logged, successful or not.
    * @parameters:
    *     - Id recordId: The Account or Lead to update (only this record
    *                    is changed).
    *     - Decimal latitude: Latitude reported by the phone.
    *     - Decimal longitude: Longitude reported by the phone.
    *     - Decimal accuracy: Accuracy of the reading in meters, as
    *                         reported by the phone.
    * @return: SaveResult with success and the message to show.
    */
    @AuraEnabled
    public static SaveResult saveLocation(Id recordId, Decimal latitude, Decimal longitude, Decimal accuracy) {
        SObject before;
        SaveResult result;
        try {
            result = validateInput(recordId, latitude, longitude, accuracy);
            if (result == null) {
                // The rep must be able to see the record (sharing applies to this read)
                if (readRecord(recordId) == null) {
                    result = fail(notFoundMessage(recordId));
                } else {
                    LocationWriter writer = new LocationWriter();
                    before = writer.lockRecord(recordId);
                    if (!canCapture(before)) {
                        result = fail(lockedMessage(recordId));
                    } else {
                        // Saved exactly as the phone reports them, with every decimal
                        writer.updateRecord(changedRecord(recordId, latitude, longitude));
                        result = new SaveResult(true, labelFor(recordId) + (hasLocation(before)
                            ? ' location updated.'
                            : ' location saved.'));
                    }
                }
            }
        } catch (DmlException e) {
            result = fail('The location could not be saved: ' + e.getDmlMessage(0));
        } catch (Exception e) {
            result = fail('The location could not be saved: ' + e.getMessage());
        }
        writeLog(recordId, before, latitude, longitude, accuracy, result);
        return result;
    }

    // ── Rules ──

    /**
    * Method Name: validateInput
    * @author: Tharun N
    * @description: Checks the record type and the phone reading before
    *               anything is read or saved: Account or Lead Id, valid
    *               coordinates (not blank, in range, not 0,0) and an
    *               accuracy no worse than the custom label allows.
    * @parameters:
    *     - Id recordId: The record the save is for.
    *     - Decimal latitude: Latitude reported by the phone.
    *     - Decimal longitude: Longitude reported by the phone.
    *     - Decimal accuracy: Accuracy of the reading in meters.
    * @return: SaveResult with the failure message, or null when the
    *          input is fine.
    */
    private static SaveResult validateInput(Id recordId, Decimal latitude, Decimal longitude, Decimal accuracy) {
        if (!isSupported(recordId)) {
            return fail(WRONG_RECORD_MESSAGE);
        }
        if (latitude == null || longitude == null
                || latitude < -90 || latitude > 90
                || longitude < -180 || longitude > 180
                || (latitude == 0 && longitude == 0)) {
            return fail('The phone did not return a valid location. Please try again.');
        }
        if (accuracy == null || accuracy < 0) {
            return fail('The phone did not report how accurate the location is. Please try again.');
        }
        Decimal maxAccuracy = maxAccuracyMeters();
        if (accuracy > maxAccuracy) {
            return fail('GPS signal is too weak (accurate to ' + accuracy.setScale(0) + ' m; needs '
                + maxAccuracy.setScale(0) + ' m or better). Move to an open area and try again.');
        }
        return null;
    }

    /**
    * Method Name: hasLocation
    * @author: Tharun N
    * @description: Tells whether the record already has a saved location
    *               (both latitude and longitude filled).
    * @parameters:
    *     - SObject rec: The Account or Lead as read from the database.
    * @return: Boolean, true when a location is saved.
    */
    private static Boolean hasLocation(SObject rec) {
        return latitudeOf(rec) != null && longitudeOf(rec) != null;
    }

    /**
    * Method Name: canCapture
    * @author: Tharun N
    * @description: The capture rule: allowed when the record has no
    *               location yet, or Override Location is ticked.
    * @parameters:
    *     - SObject rec: The Account or Lead as read from the database.
    * @return: Boolean, true when the rep may save a location now.
    */
    private static Boolean canCapture(SObject rec) {
        return !hasLocation(rec) || overrideOf(rec);
    }

    /**
    * Method Name: buildState
    * @author: Tharun N
    * @description: Builds the LocationState the component shows (title,
    *               saved location, override, locked message, accuracy
    *               limit).
    * @parameters:
    *     - Id recordId: The Account or Lead the component is on.
    *     - SObject rec: The same record as read with sharing.
    * @return: LocationState for the component.
    */
    private static LocationState buildState(Id recordId, SObject rec) {
        LocationState state = new LocationState();
        state.objectLabel = labelFor(recordId);
        state.hasLocation = hasLocation(rec);
        state.latitude = latitudeOf(rec);
        state.longitude = longitudeOf(rec);
        state.overrideAllowed = overrideOf(rec);
        state.canCapture = canCapture(rec);
        state.lockedMessage = lockedMessage(recordId);
        state.maxAccuracyMeters = maxAccuracyMeters();
        return state;
    }

    // ── Account / Lead fields ──

    /**
    * Method Name: isSupported
    * @author: Tharun N
    * @description: Tells whether the Id is an Account or a Lead, the
    *               only objects this controller works on.
    * @parameters:
    *     - Id recordId: Any record Id (may be null).
    * @return: Boolean, true for an Account or Lead Id.
    */
    private static Boolean isSupported(Id recordId) {
        return isAccount(recordId) || isLead(recordId);
    }

    /**
    * Method Name: isAccount
    * @author: Tharun N
    * @description: Tells whether the Id is an Account Id.
    * @parameters:
    *     - Id recordId: Any record Id (may be null).
    * @return: Boolean, true for an Account Id.
    */
    private static Boolean isAccount(Id recordId) {
        return recordId != null && recordId.getSObjectType() == Account.SObjectType;
    }

    /**
    * Method Name: isLead
    * @author: Tharun N
    * @description: Tells whether the Id is a Lead Id.
    * @parameters:
    *     - Id recordId: Any record Id (may be null).
    * @return: Boolean, true for a Lead Id.
    */
    private static Boolean isLead(Id recordId) {
        return recordId != null && recordId.getSObjectType() == Lead.SObjectType;
    }

    /**
    * Method Name: labelFor
    * @author: Tharun N
    * @description: Object name used in the card title and the messages.
    * @parameters:
    *     - Id recordId: The Account or Lead Id.
    * @return: String 'Lead' or 'Account'.
    */
    private static String labelFor(Id recordId) {
        return isLead(recordId) ? 'Lead' : 'Account';
    }

    /**
    * Method Name: latitudeOf
    * @author: Tharun N
    * @description: Reads the saved latitude from the object's own field
    *               (Lead_Geo_Location__c or Account_Location__c).
    * @parameters:
    *     - SObject rec: The Account or Lead (may be null).
    * @return: Decimal latitude, or null when not saved.
    */
    private static Decimal latitudeOf(SObject rec) {
        if (rec instanceof Lead) {
            return ((Lead) rec).Lead_Geo_Location__Latitude__s;
        }
        if (rec instanceof Account) {
            return ((Account) rec).Account_Location__Latitude__s;
        }
        return null;
    }

    /**
    * Method Name: longitudeOf
    * @author: Tharun N
    * @description: Reads the saved longitude from the object's own field
    *               (Lead_Geo_Location__c or Account_Location__c).
    * @parameters:
    *     - SObject rec: The Account or Lead (may be null).
    * @return: Decimal longitude, or null when not saved.
    */
    private static Decimal longitudeOf(SObject rec) {
        if (rec instanceof Lead) {
            return ((Lead) rec).Lead_Geo_Location__Longitude__s;
        }
        if (rec instanceof Account) {
            return ((Account) rec).Account_Location__Longitude__s;
        }
        return null;
    }

    /**
    * Method Name: overrideOf
    * @author: Tharun N
    * @description: Reads the record's Override Location checkbox.
    * @parameters:
    *     - SObject rec: The Account or Lead (may be null).
    * @return: Boolean, true when Override Location is ticked.
    */
    private static Boolean overrideOf(SObject rec) {
        if (rec instanceof Lead) {
            return ((Lead) rec).Location_Override__c == true;
        }
        if (rec instanceof Account) {
            return ((Account) rec).Location_Override__c == true;
        }
        return false;
    }

    /**
    * Method Name: readRecord
    * @author: Tharun N
    * @description: Reads the record's location fields with sharing, so it
    *               also confirms the rep can see the record.
    * @parameters:
    *     - Id recordId: The Account or Lead Id.
    * @return: SObject (Account or Lead), or null when it does not exist
    *          or the rep cannot see it.
    */
    private static SObject readRecord(Id recordId) {
        if (isLead(recordId)) {
            List<Lead> leads = [
                SELECT Id, Lead_Geo_Location__Latitude__s, Lead_Geo_Location__Longitude__s, Location_Override__c
                FROM Lead
                WHERE Id = :recordId
                LIMIT 1
            ];
            return leads.isEmpty() ? null : leads[0];
        }
        List<Account> accounts = [
            SELECT Id, Account_Location__Latitude__s, Account_Location__Longitude__s, Location_Override__c
            FROM Account
            WHERE Id = :recordId
            LIMIT 1
        ];
        return accounts.isEmpty() ? null : accounts[0];
    }

    /**
    * Method Name: changedRecord
    * @author: Tharun N
    * @description: Builds the update: the new location in the object's
    *               own field, and Override Location unticked.
    * @parameters:
    *     - Id recordId: The Account or Lead to update.
    *     - Decimal latitude: New latitude, saved with every decimal.
    *     - Decimal longitude: New longitude, saved with every decimal.
    * @return: SObject (Account or Lead) ready to update.
    */
    private static SObject changedRecord(Id recordId, Decimal latitude, Decimal longitude) {
        if (isLead(recordId)) {
            return new Lead(
                Id                              = recordId,
                Lead_Geo_Location__Latitude__s  = latitude,
                Lead_Geo_Location__Longitude__s = longitude,
                Location_Override__c            = false
            );
        }
        return new Account(
            Id                             = recordId,
            Account_Location__Latitude__s  = latitude,
            Account_Location__Longitude__s = longitude,
            Location_Override__c           = false
        );
    }

    // ── Config ──

    /**
    * Method Name: maxAccuracyMeters
    * @author: Tharun N
    * @description: Worst GPS accuracy accepted, from the custom label
    *               Account_Location_Max_Accuracy_Meters (used for both
    *               Account and Lead). Falls back to 100 m when the label
    *               is blank, zero or not a number.
    * @parameters: None
    * @return: Decimal accuracy limit in meters.
    */
    @TestVisible
    private static Decimal maxAccuracyMeters() {
        try {
            Decimal value = Decimal.valueOf(System.Label.Account_Location_Max_Accuracy_Meters.trim());
            return value > 0 ? value : DEFAULT_MAX_ACCURACY_METERS;
        } catch (Exception e) {
            return DEFAULT_MAX_ACCURACY_METERS;
        }
    }

    /**
    * Method Name: lockedMessage
    * @author: Tharun N
    * @description: Message telling the rep who to ask when the location
    *               is locked, from the object's own custom label.
    * @parameters:
    *     - Id recordId: The Account or Lead Id.
    * @return: String from Lead_Location_Locked_Message or
    *          Account_Location_Locked_Message.
    */
    private static String lockedMessage(Id recordId) {
        return isLead(recordId)
            ? System.Label.Lead_Location_Locked_Message
            : System.Label.Account_Location_Locked_Message;
    }

    // ── Helpers ──

    /**
    * Method Name: notFoundMessage
    * @author: Tharun N
    * @description: Message for a record that does not exist or the rep
    *               cannot see.
    * @parameters:
    *     - Id recordId: The Account or Lead Id.
    * @return: String, e.g. 'Lead not found or you do not have access to it.'
    */
    private static String notFoundMessage(Id recordId) {
        return labelFor(recordId) + ' not found or you do not have access to it.';
    }

    /**
    * Method Name: fail
    * @author: Tharun N
    * @description: Builds a failed SaveResult.
    * @parameters:
    *     - String message: The message to show the rep.
    * @return: SaveResult with success = false.
    */
    private static SaveResult fail(String message) {
        return new SaveResult(false, message);
    }

    /**
    * Method Name: newAuraError
    * @author: Tharun N
    * @description: Builds an AuraHandledException whose message reaches
    *               the component (and tests) as written.
    * @parameters:
    *     - String message: The message to show.
    * @return: AuraHandledException to throw.
    */
    private static AuraHandledException newAuraError(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    // ── Audit log: one row per save attempt ──

    /**
    * Method Name: writeLog
    * @author: Tharun N
    * @description: Writes one lcon__Error_Message_Handler__c row per save
    *               attempt (Error Point 'Account Location Update' or
    *               'Lead Location Update') with the record, old and new
    *               location, override, accuracy, distance moved, user,
    *               status and error. Logging errors are ignored so they
    *               never block the save.
    * @parameters:
    *     - Id recordId: The record the save was for.
    *     - SObject before: The record before the save (null when it was
    *                       not read).
    *     - Decimal latitude: Latitude reported by the phone.
    *     - Decimal longitude: Longitude reported by the phone.
    *     - Decimal accuracy: Accuracy reported by the phone, in meters.
    *     - SaveResult result: Outcome of the save.
    * @return: void
    */
    private static void writeLog(Id recordId, SObject before, Decimal latitude, Decimal longitude,
                                 Decimal accuracy, SaveResult result) {
        try {
            Boolean hadLocation = hasLocation(before);
            String message = (isSupported(recordId) ? labelFor(recordId) : 'Record') + ': ' + recordId
                + ', Old: ' + (hadLocation ? latitudeOf(before) + ', ' + longitudeOf(before) : 'none')
                + ', Override: ' + overrideOf(before)
                + ', New: ' + latitude + ', ' + longitude
                + ', Accuracy: ' + accuracy + ' m';
            if (hadLocation && latitude != null && longitude != null) {
                Double km = Location.getDistance(
                    Location.newInstance(latitudeOf(before), longitudeOf(before)),
                    Location.newInstance(latitude, longitude),
                    'km'
                );
                message += ', Moved: ' + Math.round(km * 1000) + ' m';
            }
            message += ', User: ' + UserInfo.getName()
                + ', Status: ' + (result.success ? 'Success' : 'Failed');
            if (!result.success) {
                message += ', Error: ' + result.message;
            }
            Database.insert(new lcon__Error_Message_Handler__c(
                lcon__Error_Message__c = message,
                lcon__Error_Point__c   = isLead(recordId) ? LEAD_LOG_POINT : ACCOUNT_LOG_POINT
            ), false);
        } catch (Exception ignored) {
            // Logging must never block the save
        }
    }

    /**
     * @description Locks, reads and updates the one record without sharing, so a rep can save the
     *              location of a record they can see but not edit. saveLocation checks the rules
     *              between lockRecord and updateRecord.
     */
    private without sharing class LocationWriter {

        /**
        * Method Name: lockRecord
        * @author: Tharun N
        * @description: Reads the record's location fields FOR UPDATE, so
        *               two saves on the same record cannot overlap.
        * @parameters:
        *     - Id recordId: The Account or Lead Id.
        * @return: SObject (Account or Lead), or null when it does not exist.
        */
        SObject lockRecord(Id recordId) {
            if (recordId.getSObjectType() == Lead.SObjectType) {
                List<Lead> leads = [
                    SELECT Id, Lead_Geo_Location__Latitude__s, Lead_Geo_Location__Longitude__s, Location_Override__c
                    FROM Lead
                    WHERE Id = :recordId
                    LIMIT 1
                    FOR UPDATE
                ];
                return leads.isEmpty() ? null : leads[0];
            }
            List<Account> accounts = [
                SELECT Id, Account_Location__Latitude__s, Account_Location__Longitude__s, Location_Override__c
                FROM Account
                WHERE Id = :recordId
                LIMIT 1
                FOR UPDATE
            ];
            return accounts.isEmpty() ? null : accounts[0];
        }

        /**
        * Method Name: updateRecord
        * @author: Tharun N
        * @description: Updates the one record built by changedRecord.
        * @parameters:
        *     - SObject record: The Account or Lead to update.
        * @return: void
        */
        void updateRecord(SObject record) {
            update record;
        }
    }
}