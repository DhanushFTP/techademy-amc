/******************************************************************
 * Class Name    : AccountLocationControllerTest
 * Company       : Fingertip Technologies Pvt Ltd
 * Created Date  : 04-11-2026
 * @description  : Tests for AccountLocationController: when a rep may
 *                 capture an account's or a lead's location, that only
 *                 the one record is changed, the one-time Override
 *                 Location, input checks, the audit log, and the
 *                 Account_Location_Locked / Lead_Location_Locked
 *                 validation rules.
 * @author       : Tharun N
 * @group        : Account
 * Used By       : - AccountLocationController
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Tharun N        | 04-11-2026 | Initial version: Account capture,
 *     |                 |            | override, input checks, log and
 *     |                 |            | Account_Location_Locked rule tests.
 * 1.1 | Tharun N        | 06-11-2026 | Lead tests: Lead state, save,
 *     |                 |            | override, locked lead, lead the rep
 *     |                 |            | cannot see, Lead_Location_Locked rule,
 *     |                 |            | 'Lead Location Update' log point.
 * 1.2 | Tharun N        | 11-11-2026 | Standard header, change log and
 *     |                 |            | method comments added. No code change.
 * -----------------------------------------------------------------------------
 ******************************************************************/
@IsTest
private class AccountLocationControllerTest {

    private static final Decimal SAVED_LAT = 12.892157;
    private static final Decimal SAVED_LNG = 77.465362;
    private static final Decimal NEW_LAT = 12.971599;
    private static final Decimal NEW_LNG = 77.594566;
    private static final Decimal GOOD_ACCURACY = 15;
    private static final String REP_LAST_NAME = 'Location Test Rep';
    private static final String LOG_POINT = 'Account Location Update';
    private static final String LEAD_LOG_POINT = 'Lead Location Update';
    private static final String LEAD_COMPANY = 'Location Test Company';

    /**
    * Method Name: setup
    * @author: Tharun N
    * @description: Creates the test rep, three admin-owned Accounts
    *               (blank, locked, override) and four Leads (three owned
    *               by the rep: blank, locked, override; one admin-owned).
    * @parameters: None
    * @return: void
    */
    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert newRep();
        }
        // Owned by the running admin, so the rep does not own (or have edit access to) any of them
        insert new List<Account>{
            new Account(Name = 'Location Test Blank', Type = 'University'),
            new Account(Name = 'Location Test Locked', Type = 'University',
                Account_Location__Latitude__s = SAVED_LAT, Account_Location__Longitude__s = SAVED_LNG),
            new Account(Name = 'Location Test Override', Type = 'University',
                Account_Location__Latitude__s = SAVED_LAT, Account_Location__Longitude__s = SAVED_LNG,
                Location_Override__c = true)
        };

        // Leads are Private: the rep owns these three, the admin owns the last one
        Id repId = rep().Id;
        List<Lead> repLeads = new List<Lead>{
            new Lead(LastName = 'Location Test Lead Blank', Company = LEAD_COMPANY, OwnerId = repId),
            new Lead(LastName = 'Location Test Lead Locked', Company = LEAD_COMPANY, OwnerId = repId,
                Lead_Geo_Location__Latitude__s = SAVED_LAT, Lead_Geo_Location__Longitude__s = SAVED_LNG),
            new Lead(LastName = 'Location Test Lead Override', Company = LEAD_COMPANY, OwnerId = repId,
                Lead_Geo_Location__Latitude__s = SAVED_LAT, Lead_Geo_Location__Longitude__s = SAVED_LNG,
                Location_Override__c = true)
        };
        insert repLeads;
        insert new Lead(LastName = 'Location Test Lead Admin Owned', Company = LEAD_COMPANY);

        // Lead assignment automation may change the owner on create, so set it again
        List<Lead> owners = new List<Lead>();
        for (Lead ld : repLeads) {
            owners.add(new Lead(Id = ld.Id, OwnerId = repId));
        }
        update owners;
    }

    // ── getLocationState ──

    /**
    * Method Name: accountWithoutLocationCanBeCaptured
    * @author: Tharun N
    * @description: An account with no location can be captured, and the
    *               accuracy limit comes from the custom label.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void accountWithoutLocationCanBeCaptured() {
        AccountLocationController.LocationState state;
        System.runAs(rep()) {
            state = AccountLocationController.getLocationState(account('Location Test Blank').Id);
        }
        Assert.isFalse(state.hasLocation, 'Blank account has no location');
        Assert.isTrue(state.canCapture, 'Blank account can be captured');
        Assert.isFalse(state.overrideAllowed, 'Override is not ticked');
        Assert.areEqual(AccountLocationController.maxAccuracyMeters(), state.maxAccuracyMeters,
            'Accuracy limit comes from the custom label');
    }

    /**
    * Method Name: accountWithLocationIsLockedWithoutOverride
    * @author: Tharun N
    * @description: An account with a location is locked without Override
    *               Location, and shows the Account locked label.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void accountWithLocationIsLockedWithoutOverride() {
        AccountLocationController.LocationState state;
        System.runAs(rep()) {
            state = AccountLocationController.getLocationState(account('Location Test Locked').Id);
        }
        Assert.isTrue(state.hasLocation, 'Account has a location');
        Assert.isFalse(state.canCapture, 'Location is locked without Override Location');
        Assert.areEqual(System.Label.Account_Location_Locked_Message, state.lockedMessage,
            'Locked message comes from the custom label');
        Assert.areEqual(SAVED_LAT, state.latitude, 'Saved latitude is returned');
        Assert.areEqual(SAVED_LNG, state.longitude, 'Saved longitude is returned');
    }

    /**
    * Method Name: accountWithOverrideCanBeCaptured
    * @author: Tharun N
    * @description: Override Location allows a new capture on an account
    *               that already has a location.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void accountWithOverrideCanBeCaptured() {
        AccountLocationController.LocationState state;
        System.runAs(rep()) {
            state = AccountLocationController.getLocationState(account('Location Test Override').Id);
        }
        Assert.isTrue(state.hasLocation, 'Account has a location');
        Assert.isTrue(state.overrideAllowed, 'Override Location is ticked');
        Assert.isTrue(state.canCapture, 'Override allows a new capture');
    }

    /**
    * Method Name: stateRejectsIdThatIsNotAnAccount
    * @author: Tharun N
    * @description: An Id that is not an Account or Lead is rejected with
    *               a clear message.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void stateRejectsIdThatIsNotAnAccount() {
        try {
            AccountLocationController.getLocationState(UserInfo.getUserId());
            Assert.fail('A non-Account Id should be rejected');
        } catch (AuraHandledException e) {
            Assert.areEqual('Open this from an Account or Lead record.', e.getMessage(), 'Clear message for a wrong Id');
        }
    }

    /**
    * Method Name: stateForMissingAccountIsRejected
    * @author: Tharun N
    * @description: A deleted account is rejected with a 'not found'
    *               message.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void stateForMissingAccountIsRejected() {
        Account gone = new Account(Name = 'Location Test Deleted', Type = 'University');
        insert gone;
        delete gone;
        try {
            AccountLocationController.getLocationState(gone.Id);
            Assert.fail('A deleted account should be rejected');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('not found'), 'Clear message for a missing account');
        }
    }

    // ── saveLocation: allowed saves ──

    /**
    * Method Name: repSavesLocationOnBlankAccountTheyDoNotOwn
    * @author: Tharun N
    * @description: A rep can save the location of a blank account they
    *               do not own; the save is logged as a success.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void repSavesLocationOnBlankAccountTheyDoNotOwn() {
        Id accountId = account('Location Test Blank').Id;
        AccountLocationController.SaveResult result;
        System.runAs(rep()) {
            Test.startTest();
            result = AccountLocationController.saveLocation(accountId, NEW_LAT, NEW_LNG, GOOD_ACCURACY);
            Test.stopTest();
        }
        Assert.isTrue(result.success, 'Save should succeed: ' + result.message);
        Assert.areEqual('Account location saved.', result.message, 'First capture message');
        Account saved = reload(accountId);
        Assert.areEqual(NEW_LAT, saved.Account_Location__Latitude__s, 'Latitude saved');
        Assert.areEqual(NEW_LNG, saved.Account_Location__Longitude__s, 'Longitude saved');
        Assert.isFalse(saved.Location_Override__c, 'Override stays unticked');
        Assert.areEqual(1, logCount('Status: Success'), 'Successful save is logged');
    }

    /**
    * Method Name: overrideAllowsOneUpdateThenLocksAgain
    * @author: Tharun N
    * @description: Override Location allows exactly one update, is
    *               unticked by it, and the second attempt is refused and
    *               logged with the distance moved.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void overrideAllowsOneUpdateThenLocksAgain() {
        Id accountId = account('Location Test Override').Id;
        AccountLocationController.SaveResult first;
        AccountLocationController.SaveResult second;
        System.runAs(rep()) {
            Test.startTest();
            first = AccountLocationController.saveLocation(accountId, NEW_LAT, NEW_LNG, GOOD_ACCURACY);
            second = AccountLocationController.saveLocation(accountId, SAVED_LAT, SAVED_LNG, GOOD_ACCURACY);
            Test.stopTest();
        }
        Assert.isTrue(first.success, 'Override update should succeed: ' + first.message);
        Assert.areEqual('Account location updated.', first.message, 'Override update message');
        Assert.isFalse(second.success, 'Second update needs a new override');
        Assert.areEqual(System.Label.Account_Location_Locked_Message, second.message, 'Locked message shown');

        Account saved = reload(accountId);
        Assert.areEqual(NEW_LAT, saved.Account_Location__Latitude__s, 'First update kept');
        Assert.areEqual(NEW_LNG, saved.Account_Location__Longitude__s, 'First update kept');
        Assert.isFalse(saved.Location_Override__c, 'Override unticked by the save');
        Assert.areEqual(1, logCount('Status: Success'), 'Override update is logged');
        Assert.areEqual(1, logCount('Status: Failed'), 'Refused second update is logged');
        Assert.areEqual(2, logCount('Moved: '), 'Both attempts log the distance from the saved location');
    }

    /**
    * Method Name: onlyTheGivenAccountIsChanged
    * @author: Tharun N
    * @description: A save changes only the account passed in; the other
    *               test accounts keep their locations.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void onlyTheGivenAccountIsChanged() {
        Id accountId = account('Location Test Override').Id;
        System.runAs(rep()) {
            AccountLocationController.saveLocation(accountId, NEW_LAT, NEW_LNG, GOOD_ACCURACY);
        }
        for (Account other : [
            SELECT Name, Account_Location__Latitude__s, Account_Location__Longitude__s, Location_Override__c
            FROM Account
            WHERE Id != :accountId AND Name LIKE 'Location Test%'
        ]) {
            Assert.areNotEqual(NEW_LAT, other.Account_Location__Latitude__s, other.Name + ' must not change');
        }
        Assert.areEqual(NEW_LAT, reload(accountId).Account_Location__Latitude__s, 'Target account changed');
    }

    /**
    * Method Name: coordinatesAreSavedWithAllDecimals
    * @author: Tharun N
    * @description: Coordinates are saved exactly as the phone reports
    *               them, without rounding to 6 decimals.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void coordinatesAreSavedWithAllDecimals() {
        Decimal phoneLat = 12.974468821230008;
        Decimal phoneLng = 77.60175432500743;
        Id accountId = account('Location Test Blank').Id;
        System.runAs(rep()) {
            AccountLocationController.saveLocation(accountId, phoneLat, phoneLng, GOOD_ACCURACY);
        }
        Account saved = reload(accountId);
        // Rounding to 6 decimals would be off by up to 0.0000005, far more than this tolerance
        Assert.isTrue(Math.abs(saved.Account_Location__Latitude__s - phoneLat) < 0.000000000001,
            'Latitude saved with all decimals, got ' + saved.Account_Location__Latitude__s);
        Assert.isTrue(Math.abs(saved.Account_Location__Longitude__s - phoneLng) < 0.000000000001,
            'Longitude saved with all decimals, got ' + saved.Account_Location__Longitude__s);
    }

    // ── saveLocation: refused saves ──

    /**
    * Method Name: lockedAccountIsNotChanged
    * @author: Tharun N
    * @description: A locked account is not changed, the locked message
    *               is returned and the refusal is logged.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void lockedAccountIsNotChanged() {
        Id accountId = account('Location Test Locked').Id;
        AccountLocationController.SaveResult result;
        System.runAs(rep()) {
            result = AccountLocationController.saveLocation(accountId, NEW_LAT, NEW_LNG, GOOD_ACCURACY);
        }
        Assert.isFalse(result.success, 'Locked account must not be updated');
        Assert.areEqual(System.Label.Account_Location_Locked_Message, result.message, 'Locked message shown');
        Account saved = reload(accountId);
        Assert.areEqual(SAVED_LAT, saved.Account_Location__Latitude__s, 'Latitude unchanged');
        Assert.areEqual(SAVED_LNG, saved.Account_Location__Longitude__s, 'Longitude unchanged');
        Assert.areEqual(1, logCount('Status: Failed'), 'Refused save is logged');
    }

    /**
    * Method Name: invalidCoordinatesAreRefused
    * @author: Tharun N
    * @description: Blank, out-of-range and 0,0 readings are refused and
    *               nothing is saved.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void invalidCoordinatesAreRefused() {
        Id accountId = account('Location Test Blank').Id;
        List<List<Decimal>> badReadings = new List<List<Decimal>>{
            new List<Decimal>{ null, NEW_LNG },
            new List<Decimal>{ NEW_LAT, null },
            new List<Decimal>{ 95, NEW_LNG },
            new List<Decimal>{ NEW_LAT, 181 },
            new List<Decimal>{ 0, 0 }
        };
        System.runAs(rep()) {
            for (List<Decimal> reading : badReadings) {
                AccountLocationController.SaveResult result =
                    AccountLocationController.saveLocation(accountId, reading[0], reading[1], GOOD_ACCURACY);
                Assert.isFalse(result.success, 'Bad reading refused: ' + reading);
            }
        }
        Assert.isNull(reload(accountId).Account_Location__Latitude__s, 'Nothing saved');
    }

    /**
    * Method Name: weakOrMissingAccuracyIsRefused
    * @author: Tharun N
    * @description: A reading weaker than the accuracy limit, or with no
    *               accuracy, is refused and nothing is saved.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void weakOrMissingAccuracyIsRefused() {
        Id accountId = account('Location Test Blank').Id;
        Decimal tooWeak = AccountLocationController.maxAccuracyMeters() + 1;
        AccountLocationController.SaveResult weak;
        AccountLocationController.SaveResult missing;
        System.runAs(rep()) {
            weak = AccountLocationController.saveLocation(accountId, NEW_LAT, NEW_LNG, tooWeak);
            missing = AccountLocationController.saveLocation(accountId, NEW_LAT, NEW_LNG, null);
        }
        Assert.isFalse(weak.success, 'Weak GPS refused');
        Assert.isTrue(weak.message.contains('too weak'), 'Weak GPS message');
        Assert.isFalse(missing.success, 'Missing accuracy refused');
        Assert.isNull(reload(accountId).Account_Location__Latitude__s, 'Nothing saved');
    }

    /**
    * Method Name: wrongOrMissingAccountIsRefused
    * @author: Tharun N
    * @description: A save for a non-Account Id or a deleted account is
    *               refused with a clear message.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void wrongOrMissingAccountIsRefused() {
        Account gone = new Account(Name = 'Location Test Deleted', Type = 'University');
        insert gone;
        delete gone;
        AccountLocationController.SaveResult wrongType;
        AccountLocationController.SaveResult missing;
        System.runAs(rep()) {
            wrongType = AccountLocationController.saveLocation(UserInfo.getUserId(), NEW_LAT, NEW_LNG, GOOD_ACCURACY);
            missing = AccountLocationController.saveLocation(gone.Id, NEW_LAT, NEW_LNG, GOOD_ACCURACY);
        }
        Assert.isFalse(wrongType.success, 'Non-Account Id refused');
        Assert.isFalse(missing.success, 'Deleted account refused');
        Assert.isTrue(missing.message.contains('not found'), 'Missing account message');
    }

    // ── Account_Location_Locked validation rule ──

    /**
    * Method Name: ruleBlocksManualChangeOfLockedLocation
    * @author: Tharun N
    * @description: Account_Location_Locked blocks a rep from editing a
    *               locked account location by hand.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void ruleBlocksManualChangeOfLockedLocation() {
        User rep = rep();
        Account owned = new Account(Name = 'Location Test Rep Owned', Type = 'University', OwnerId = rep.Id,
            Account_Location__Latitude__s = SAVED_LAT, Account_Location__Longitude__s = SAVED_LNG);
        insert owned;
        System.runAs(rep) {
            try {
                update new Account(Id = owned.Id, Account_Location__Latitude__s = NEW_LAT);
                Assert.fail('Manual change of a locked location should be blocked');
            } catch (DmlException e) {
                Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, e.getDmlType(0),
                    'Blocked by Account_Location_Locked');
            }
        }
    }

    /**
    * Method Name: ruleAllowsManualChangeWhenOverrideTicked
    * @author: Tharun N
    * @description: Account_Location_Locked allows a hand edit when
    *               Override Location is ticked.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void ruleAllowsManualChangeWhenOverrideTicked() {
        User rep = rep();
        Account owned = new Account(Name = 'Location Test Rep Owned', Type = 'University', OwnerId = rep.Id,
            Account_Location__Latitude__s = SAVED_LAT, Account_Location__Longitude__s = SAVED_LNG,
            Location_Override__c = true);
        insert owned;
        System.runAs(rep) {
            update new Account(Id = owned.Id, Account_Location__Latitude__s = NEW_LAT, Location_Override__c = false);
        }
        Assert.areEqual(NEW_LAT, reload(owned.Id).Account_Location__Latitude__s, 'Override allowed the change');
    }

    /**
    * Method Name: ruleExemptsSystemAdministrator
    * @author: Tharun N
    * @description: A System Administrator can correct a locked account
    *               location without Override Location.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void ruleExemptsSystemAdministrator() {
        List<User> admins = [
            SELECT Id FROM User
            WHERE Profile.Name = 'System Administrator' AND IsActive = true
            LIMIT 1
        ];
        Assert.isFalse(admins.isEmpty(), 'An active System Administrator is needed for this test');
        Id accountId = account('Location Test Locked').Id;
        System.runAs(admins[0]) {
            update new Account(Id = accountId, Account_Location__Latitude__s = NEW_LAT);
        }
        Assert.areEqual(NEW_LAT, reload(accountId).Account_Location__Latitude__s, 'Admin can correct a location');
    }

    // ── Lead: getLocationState ──

    /**
    * Method Name: leadWithoutLocationCanBeCaptured
    * @author: Tharun N
    * @description: A lead with no location can be captured, and the card
    *               is labelled 'Lead'.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void leadWithoutLocationCanBeCaptured() {
        AccountLocationController.LocationState state;
        System.runAs(rep()) {
            state = AccountLocationController.getLocationState(lead('Location Test Lead Blank').Id);
        }
        Assert.areEqual('Lead', state.objectLabel, 'Card is labelled for a lead');
        Assert.isFalse(state.hasLocation, 'Blank lead has no location');
        Assert.isTrue(state.canCapture, 'Blank lead can be captured');
    }

    /**
    * Method Name: leadWithLocationIsLockedWithoutOverride
    * @author: Tharun N
    * @description: A lead with a location is locked without Override
    *               Location, and shows the Lead locked label.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void leadWithLocationIsLockedWithoutOverride() {
        AccountLocationController.LocationState state;
        System.runAs(rep()) {
            state = AccountLocationController.getLocationState(lead('Location Test Lead Locked').Id);
        }
        Assert.isTrue(state.hasLocation, 'Lead has a location');
        Assert.isFalse(state.canCapture, 'Lead location is locked without Override Location');
        Assert.areEqual(System.Label.Lead_Location_Locked_Message, state.lockedMessage,
            'Lead locked message comes from its own label');
        Assert.areEqual(SAVED_LAT, state.latitude, 'Saved latitude is returned');
    }

    /**
    * Method Name: accountStateIsLabelledAccount
    * @author: Tharun N
    * @description: On an account, the card is labelled 'Account'.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void accountStateIsLabelledAccount() {
        AccountLocationController.LocationState state;
        System.runAs(rep()) {
            state = AccountLocationController.getLocationState(account('Location Test Blank').Id);
        }
        Assert.areEqual('Account', state.objectLabel, 'Card is labelled for an account');
    }

    // ── Lead: saveLocation ──

    /**
    * Method Name: repSavesLocationOnLead
    * @author: Tharun N
    * @description: A rep can save a lead's location into Lead Geo
    *               Location; it is logged under 'Lead Location Update',
    *               not as an account update.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void repSavesLocationOnLead() {
        Id leadId = lead('Location Test Lead Blank').Id;
        AccountLocationController.SaveResult result;
        System.runAs(rep()) {
            Test.startTest();
            result = AccountLocationController.saveLocation(leadId, NEW_LAT, NEW_LNG, GOOD_ACCURACY);
            Test.stopTest();
        }
        Assert.isTrue(result.success, 'Lead save should succeed: ' + result.message);
        Assert.areEqual('Lead location saved.', result.message, 'First capture message');
        Lead saved = reloadLead(leadId);
        Assert.areEqual(NEW_LAT, saved.Lead_Geo_Location__Latitude__s, 'Latitude saved');
        Assert.areEqual(NEW_LNG, saved.Lead_Geo_Location__Longitude__s, 'Longitude saved');
        Assert.isFalse(saved.Location_Override__c, 'Override stays unticked');
        Assert.areEqual(1, logCount(LEAD_LOG_POINT, 'Status: Success'), 'Logged under Lead Location Update');
        Assert.areEqual(0, logCount(LOG_POINT, 'Status: Success'), 'Not logged as an account update');
    }

    /**
    * Method Name: leadOverrideAllowsOneUpdateThenLocksAgain
    * @author: Tharun N
    * @description: The Lead Override Location allows exactly one update,
    *               then the lead is locked again with the Lead message.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void leadOverrideAllowsOneUpdateThenLocksAgain() {
        Id leadId = lead('Location Test Lead Override').Id;
        AccountLocationController.SaveResult first;
        AccountLocationController.SaveResult second;
        System.runAs(rep()) {
            Test.startTest();
            first = AccountLocationController.saveLocation(leadId, NEW_LAT, NEW_LNG, GOOD_ACCURACY);
            second = AccountLocationController.saveLocation(leadId, SAVED_LAT, SAVED_LNG, GOOD_ACCURACY);
            Test.stopTest();
        }
        Assert.isTrue(first.success, 'Override update should succeed: ' + first.message);
        Assert.areEqual('Lead location updated.', first.message, 'Override update message');
        Assert.isFalse(second.success, 'Second update needs a new override');
        Assert.areEqual(System.Label.Lead_Location_Locked_Message, second.message, 'Lead locked message shown');
        Lead saved = reloadLead(leadId);
        Assert.areEqual(NEW_LAT, saved.Lead_Geo_Location__Latitude__s, 'First update kept');
        Assert.isFalse(saved.Location_Override__c, 'Override unticked by the save');
        Assert.areEqual(1, logCount(LEAD_LOG_POINT, 'Status: Failed'), 'Refused second update is logged');
    }

    /**
    * Method Name: lockedLeadIsNotChanged
    * @author: Tharun N
    * @description: A locked lead is not changed.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void lockedLeadIsNotChanged() {
        Id leadId = lead('Location Test Lead Locked').Id;
        AccountLocationController.SaveResult result;
        System.runAs(rep()) {
            result = AccountLocationController.saveLocation(leadId, NEW_LAT, NEW_LNG, GOOD_ACCURACY);
        }
        Assert.isFalse(result.success, 'Locked lead must not be updated');
        Assert.areEqual(SAVED_LAT, reloadLead(leadId).Lead_Geo_Location__Latitude__s, 'Latitude unchanged');
    }

    /**
    * Method Name: leadTheRepCannotSeeIsRefused
    * @author: Tharun N
    * @description: A lead the rep cannot see is refused with 'not found'.
    *               If the org's lead sharing lets the rep see it, the
    *               save is allowed like any visible blank lead.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void leadTheRepCannotSeeIsRefused() {
        Id leadId = lead('Location Test Lead Admin Owned').Id;
        Boolean visible = true;
        AccountLocationController.SaveResult result;
        System.runAs(rep()) {
            try {
                AccountLocationController.getLocationState(leadId);
            } catch (AuraHandledException e) {
                visible = false;
            }
            result = AccountLocationController.saveLocation(leadId, NEW_LAT, NEW_LNG, GOOD_ACCURACY);
        }
        if (visible) {
            // Lead sharing in this org lets the rep see the lead, so the save is allowed like any visible lead
            Assert.isTrue(result.success, 'Visible blank lead can be captured: ' + result.message);
        } else {
            Assert.isFalse(result.success, 'A lead the rep cannot see is refused');
            Assert.isTrue(result.message.contains('not found'), 'Clear message: ' + result.message);
            Assert.isNull(reloadLead(leadId).Lead_Geo_Location__Latitude__s, 'Nothing saved');
        }
    }

    // ── Lead_Location_Locked validation rule ──

    /**
    * Method Name: leadRuleBlocksManualChangeOfLockedLocation
    * @author: Tharun N
    * @description: Lead_Location_Locked blocks a rep from editing a
    *               locked lead location by hand.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void leadRuleBlocksManualChangeOfLockedLocation() {
        Id leadId = lead('Location Test Lead Locked').Id;
        System.runAs(rep()) {
            try {
                update new Lead(Id = leadId, Lead_Geo_Location__Latitude__s = NEW_LAT);
                Assert.fail('Manual change of a locked lead location should be blocked');
            } catch (DmlException e) {
                Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, e.getDmlType(0),
                    'Blocked by Lead_Location_Locked');
            }
        }
    }

    /**
    * Method Name: leadRuleAllowsManualChangeWhenOverrideTicked
    * @author: Tharun N
    * @description: Lead_Location_Locked allows a hand edit when the Lead
    *               Override Location is ticked.
    * @parameters: None
    * @return: void
    */
    @IsTest
    static void leadRuleAllowsManualChangeWhenOverrideTicked() {
        Id leadId = lead('Location Test Lead Override').Id;
        System.runAs(rep()) {
            update new Lead(Id = leadId, Lead_Geo_Location__Latitude__s = NEW_LAT, Location_Override__c = false);
        }
        Assert.areEqual(NEW_LAT, reloadLead(leadId).Lead_Geo_Location__Latitude__s, 'Override allowed the change');
    }

    // ── Helpers ──

    /**
    * Method Name: newRep
    * @author: Tharun N
    * @description: Builds the test rep user with the B2A Account manager
    *               profile (field reps), or Standard User as a fallback.
    * @parameters: None
    * @return: User (not inserted).
    */
    private static User newRep() {
        // The B2A Account manager profile is what field reps use; Standard User is the fallback
        Profile repProfile = [
            SELECT Id FROM Profile
            WHERE Name IN ('B2A Account manager', 'Standard User')
            ORDER BY Name
            LIMIT 1
        ];
        String unique = String.valueOf(System.currentTimeMillis());
        return new User(
            Username          = 'location.rep.' + unique + '@locationtest.com.invalid',
            LastName          = REP_LAST_NAME,
            Email             = 'location.rep@locationtest.com.invalid',
            Alias             = 'locrep',
            TimeZoneSidKey    = 'Asia/Kolkata',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId         = repProfile.Id
        );
    }

    /**
    * Method Name: rep
    * @author: Tharun N
    * @description: Returns the test rep created in setup.
    * @parameters: None
    * @return: User
    */
    private static User rep() {
        return [SELECT Id FROM User WHERE LastName = :REP_LAST_NAME LIMIT 1];
    }

    /**
    * Method Name: account
    * @author: Tharun N
    * @description: Returns a test account by name.
    * @parameters:
    *     - String name: Account name.
    * @return: Account
    */
    private static Account account(String name) {
        return [SELECT Id FROM Account WHERE Name = :name LIMIT 1];
    }

    /**
    * Method Name: reload
    * @author: Tharun N
    * @description: Re-reads an account's location fields after a save.
    * @parameters:
    *     - Id accountId: The account to read.
    * @return: Account
    */
    private static Account reload(Id accountId) {
        return [
            SELECT Account_Location__Latitude__s, Account_Location__Longitude__s, Location_Override__c
            FROM Account
            WHERE Id = :accountId
        ];
    }

    /**
    * Method Name: lead
    * @author: Tharun N
    * @description: Returns a test lead by last name.
    * @parameters:
    *     - String lastName: Lead last name.
    * @return: Lead
    */
    private static Lead lead(String lastName) {
        return [SELECT Id FROM Lead WHERE LastName = :lastName LIMIT 1];
    }

    /**
    * Method Name: reloadLead
    * @author: Tharun N
    * @description: Re-reads a lead's location fields after a save.
    * @parameters:
    *     - Id leadId: The lead to read.
    * @return: Lead
    */
    private static Lead reloadLead(Id leadId) {
        return [
            SELECT Lead_Geo_Location__Latitude__s, Lead_Geo_Location__Longitude__s, Location_Override__c
            FROM Lead
            WHERE Id = :leadId
        ];
    }

    /**
    * Method Name: logCount
    * @author: Tharun N
    * @description: Counts 'Account Location Update' log rows whose
    *               message contains the given text.
    * @parameters:
    *     - String contains: Text to look for in the log message.
    * @return: Integer count of matching rows.
    */
    private static Integer logCount(String contains) {
        return logCount(LOG_POINT, contains);
    }

    /**
    * Method Name: logCount
    * @author: Tharun N
    * @description: Counts log rows for an Error Point whose message
    *               contains the given text. Long text area cannot be
    *               filtered in SOQL, so the match is done here.
    * @parameters:
    *     - String errorPoint: 'Account Location Update' or
    *                          'Lead Location Update'.
    *     - String contains: Text to look for in the log message.
    * @return: Integer count of matching rows.
    */
    private static Integer logCount(String errorPoint, String contains) {
        Integer count = 0;
        for (lcon__Error_Message_Handler__c log : [
            SELECT lcon__Error_Message__c FROM lcon__Error_Message_Handler__c
            WHERE lcon__Error_Point__c = :errorPoint
        ]) {
            if (log.lcon__Error_Message__c != null && log.lcon__Error_Message__c.contains(contains)) {
                count++;
            }
        }
        return count;
    }
}