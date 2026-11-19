/******************************************************************
 * Component Name : accountLocationCapture
 * Company        : Fingertip Technologies Pvt Ltd
 * Created Date   : 04-11-2026
 * @description   : Location Capture (Account and Lead). Shows the
 *                  record's saved location and lets a rep save their
 *                  phone's current location to it. One component for
 *                  both objects:
 *                    Account -> Account Location
 *                    Lead    -> Lead Geo Location
 *                  What the rep sees:
 *                    - No location saved           -> capture button
 *                    - Override Location ticked    -> update button
 *                      (Override unticks itself after the save)
 *                    - Location saved, no override -> message saying
 *                      who to ask; no button
 *                    - On a laptop                 -> note to use the
 *                      phone (capture works on the phone only)
 *                  Phone location ON / OFF and GPS accuracy are checked
 *                  here before saving. The same rules are checked again
 *                  in AccountLocationController, which updates only this
 *                  record.
 * @author        : Tharun N
 * Used By        : - Account Lightning Record Page (card)
 *                  - Lead Lightning Record Page (card, laptop)
 *                  - locationCaptureWrapper (Aura): Lead "Capture
 *                    Location" quick action (phone)
 * Apex           : AccountLocationController
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Tharun N        | 04-11-2026 | Initial version: Account Location
 *     |                 |            | card, phone GPS ON / OFF and
 *     |                 |            | accuracy check, save and override
 *     |                 |            | update, locked message.
 * 1.1 | Tharun N        | 06-11-2026 | Lead support: sends recordId to
 *     |                 |            | Apex (was accountId); card title and
 *     |                 |            | messages use the object name
 *     |                 |            | (cardTitle, recordNoun); exposed on
 *     |                 |            | Lead pages and opened from the Lead
 *     |                 |            | Capture Location action.
 * 1.2 | Tharun N        | 11-11-2026 | Standard header, change log and
 *     |                 |            | method comments added. No code change.
 * -----------------------------------------------------------------------------
 ******************************************************************/
import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { getLocationService } from 'lightning/mobileCapabilities';
import FORM_FACTOR from '@salesforce/client/formFactor';
import getLocationState from '@salesforce/apex/AccountLocationController.getLocationState';
import saveLocation from '@salesforce/apex/AccountLocationController.saveLocation';

const GPS_TIMEOUT_MS = 20000;
const EARTH_RADIUS_METERS = 6371000;

const GPS = {
    CHECKING: 'checking',
    ON: 'on',
    WEAK: 'weak',
    OFF: 'off'
};

const MSG_LOCATION_OFF = 'Location is OFF on your phone. Turn on Location and tap Retry.';
const MSG_PERMISSION = 'Location access is blocked for the Salesforce app. Allow it in your phone Settings and tap Retry.';

export default class AccountLocationCapture extends LightningElement {
    @api recordId;

    state;
    loadError;
    isLoading = true;
    isSaving = false;
    gpsStatus;
    gpsMessage;
    reading; // { latitude, longitude, accuracy }

    isPhone = FORM_FACTOR === 'Small';

    /**
    * Method Name: connectedCallback
    * @author: Tharun N
    * @description: Loads the record's location state when the card opens.
    * @parameters: None
    * @return: void
    */
    connectedCallback() {
        this.loadState();
    }

    // ── Data ──

    /**
    * Method Name: loadState
    * @author: Tharun N
    * @description: Gets the saved location and capture rules from
    *               AccountLocationController.getLocationState, then
    *               starts the GPS check when the rep can capture on a
    *               phone.
    * @parameters: None
    * @return: Promise<void>
    */
    async loadState() {
        this.isLoading = true;
        this.loadError = undefined;
        try {
            this.state = await getLocationState({ recordId: this.recordId });
        } catch (error) {
            this.state = undefined;
            this.loadError = errorText(error);
        } finally {
            this.isLoading = false;
        }
        if (this.showCapture) {
            this.checkLocation();
        }
    }

    // ── Template state (getters used by the HTML) ──

    // "Account Location" or "Lead Location"
    get cardTitle() {
        return this.state?.objectLabel ? `${this.state.objectLabel} Location` : 'Location';
    }

    // "account" or "lead" in the messages
    get recordNoun() {
        return this.state?.objectLabel ? this.state.objectLabel.toLowerCase() : 'record';
    }

    // True when the record already has a saved location
    get hasLocation() {
        return this.state?.hasLocation === true;
    }

    // Saved location as "latitude, longitude"
    get savedLocationText() {
        return this.hasLocation
            ? `${formatCoordinate(this.state.latitude)}, ${formatCoordinate(this.state.longitude)}`
            : '';
    }

    // Location set and not approved for override: show who to ask
    get showLocked() {
        return this.state?.canCapture === false;
    }

    // Capture allowed but not on a phone: show the "use your phone" note
    get showDesktopNote() {
        return this.state?.canCapture === true && !this.isPhone;
    }

    // Capture allowed on a phone: show the GPS status and save button
    get showCapture() {
        return this.state?.canCapture === true && this.isPhone;
    }

    // Updating an existing location under Override Location
    get isOverride() {
        return this.hasLocation && this.state.overrideAllowed === true;
    }

    get isChecking() {
        return this.gpsStatus === GPS.CHECKING;
    }

    get showRetry() {
        return this.gpsStatus === GPS.OFF || this.gpsStatus === GPS.WEAK;
    }

    // Save only with a usable GPS reading, and not twice at once
    get isSaveDisabled() {
        return this.gpsStatus !== GPS.ON || this.isSaving;
    }

    get saveLabel() {
        if (this.isSaving) {
            return 'Saving…';
        }
        return this.hasLocation ? 'Update Location' : 'Save My Location';
    }

    // GPS status icon, colour and text style
    get gpsIconName() {
        switch (this.gpsStatus) {
            case GPS.ON:
                return 'utility:success';
            case GPS.WEAK:
                return 'utility:warning';
            case GPS.OFF:
                return 'utility:error';
            default:
                return 'utility:location';
        }
    }

    get gpsIconVariant() {
        switch (this.gpsStatus) {
            case GPS.ON:
                return 'success';
            case GPS.WEAK:
                return 'warning';
            case GPS.OFF:
                return 'error';
            default:
                return undefined;
        }
    }

    get gpsTextClass() {
        if (this.gpsStatus === GPS.ON) {
            return 'slds-text-body_small slds-text-color_success';
        }
        if (this.gpsStatus === GPS.OFF) {
            return 'slds-text-body_small slds-text-color_error';
        }
        return 'slds-text-body_small';
    }

    // Under override: how far the rep is from the saved location
    get moveText() {
        if (!this.isOverride || this.gpsStatus !== GPS.ON || !this.reading) {
            return '';
        }
        const meters = distanceMeters(
            this.state.latitude,
            this.state.longitude,
            this.reading.latitude,
            this.reading.longitude
        );
        return `You are about ${formatDistance(meters)} from the saved location.`;
    }

    // ── Handlers ──

    /**
    * Method Name: handleRetry
    * @author: Tharun N
    * @description: Retry button: reads the phone location again.
    * @parameters: None
    * @return: void
    */
    handleRetry() {
        this.checkLocation();
    }

    /**
    * Method Name: handleSave
    * @author: Tharun N
    * @description: Save / Update button: takes a fresh GPS reading, sends
    *               it to AccountLocationController.saveLocation, shows the
    *               result as a toast, refreshes the record page and
    *               reloads the card.
    * @parameters: None
    * @return: Promise<void>
    */
    async handleSave() {
        this.isSaving = true;
        try {
            // Fresh reading, so the saved location is where the rep is standing now
            const ready = await this.checkLocation();
            if (!ready) {
                return;
            }
            const result = await saveLocation({
                recordId: this.recordId,
                latitude: this.reading.latitude,
                longitude: this.reading.longitude,
                accuracy: this.reading.accuracy
            });
            if (result.success) {
                this.toast('Location Saved', result.message, 'success');
                notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            } else {
                this.toast('Location Not Saved', result.message, 'error', 'sticky');
            }
            await this.loadState();
        } catch (error) {
            this.toast('Location Not Saved', errorText(error), 'error', 'sticky');
        } finally {
            this.isSaving = false;
        }
    }

    // ── Location ON / OFF check ──

    /**
    * Method Name: checkLocation
    * @author: Tharun N
    * @description: Reads the phone position and sets gpsStatus: ON
    *               (usable), WEAK (accuracy worse than the limit, or not
    *               reported) or OFF (location off or blocked).
    * @parameters: None
    * @return: Promise<Boolean>, true when the reading can be saved.
    */
    async checkLocation() {
        this.gpsStatus = GPS.CHECKING;
        this.gpsMessage = 'Checking your phone location…';
        this.reading = undefined;
        try {
            const coords = await this.getPosition();
            const accuracy = typeof coords.accuracy === 'number' ? coords.accuracy : null;
            const maxAccuracy = this.state.maxAccuracyMeters;
            this.reading = {
                latitude: coords.latitude,
                longitude: coords.longitude,
                accuracy
            };
            if (accuracy === null) {
                this.gpsStatus = GPS.WEAK;
                this.gpsMessage = 'Location is ON but the phone did not report its accuracy. Tap Retry.';
            } else if (accuracy > maxAccuracy) {
                this.gpsStatus = GPS.WEAK;
                this.gpsMessage = `Location is ON but the GPS signal is weak (±${Math.round(accuracy)} m; needs ${maxAccuracy} m or better). Move to an open area and tap Retry.`;
            } else {
                this.gpsStatus = GPS.ON;
                this.gpsMessage = `Location is ON (accurate to ±${Math.round(accuracy)} m).`;
            }
        } catch (error) {
            this.gpsStatus = GPS.OFF;
            this.gpsMessage = error.message || MSG_LOCATION_OFF;
        }
        return this.gpsStatus === GPS.ON;
    }

    /**
    * Method Name: getPosition
    * @author: Tharun N
    * @description: Uses the Salesforce mobile app's location service when
    *               available (it reports when phone location is switched
    *               off), otherwise the browser geolocation API.
    * @parameters: None
    * @return: Promise of the position coords (latitude, longitude,
    *          accuracy). Rejects with a message the rep can act on.
    */
    getPosition() {
        const locationService = getLocationService();
        if (locationService && locationService.isAvailable()) {
            return locationService
                .getCurrentPosition({
                    enableHighAccuracy: true,
                    permissionRationaleText: 'Salesforce uses your location to save this record\'s location.'
                })
                .then((result) => result.coords)
                .catch((error) => {
                    const message = nativeErrorText(error);
                    if (message) {
                        throw new Error(message);
                    }
                    return this.getBrowserPosition();
                });
        }
        return this.getBrowserPosition();
    }

    /**
    * Method Name: getBrowserPosition
    * @author: Tharun N
    * @description: Browser geolocation fallback: high accuracy, no cached
    *               reading, 20 second timeout. Turns the browser error
    *               codes into rep-friendly messages.
    * @parameters: None
    * @return: Promise of the position coords.
    */
    getBrowserPosition() {
        return new Promise((resolve, reject) => {
            if (!navigator.geolocation) {
                reject(new Error('Location is not supported on this device.'));
                return;
            }
            navigator.geolocation.getCurrentPosition(
                (position) => resolve(position.coords),
                (error) => {
                    if (error.code === 1) {
                        reject(new Error(MSG_PERMISSION));
                    } else if (error.code === 2) {
                        reject(new Error(MSG_LOCATION_OFF));
                    } else {
                        reject(new Error('Getting your location timed out. Check Location is ON and tap Retry.'));
                    }
                },
                { enableHighAccuracy: true, timeout: GPS_TIMEOUT_MS, maximumAge: 0 }
            );
        });
    }

    /**
    * Method Name: toast
    * @author: Tharun N
    * @description: Shows a toast message.
    * @parameters:
    *     - String title: Toast title.
    *     - String message: Toast message.
    *     - String variant: success, error, warning or info.
    *     - String mode: dismissable (default) or sticky.
    * @return: void
    */
    toast(title, message, variant, mode = 'dismissable') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
    }
}

// ── Helpers ──

/**
* Method Name: nativeErrorText
* @author: Tharun N
* @description: Message for a Salesforce mobile app location error the
*               rep can fix (location off, permission denied).
* @parameters:
*     - Object error: Error from the mobile location service.
* @return: String message, or null to fall back to the browser.
*/
function nativeErrorText(error) {
    switch (error?.code) {
        case 'LOCATION_SERVICE_DISABLED':
            return MSG_LOCATION_OFF;
        case 'USER_DENIED_PERMISSION':
        case 'USER_DISABLED_PERMISSION':
            return MSG_PERMISSION;
        default:
            return null;
    }
}

/**
* Method Name: errorText
* @author: Tharun N
* @description: Readable text from an Apex or JavaScript error.
* @parameters:
*     - Object error: The error caught.
* @return: String message.
*/
function errorText(error) {
    return error?.body?.message || error?.message || 'Something went wrong. Please try again.';
}

/**
* Method Name: formatCoordinate
* @author: Tharun N
* @description: Shows the coordinate exactly as saved, with every decimal.
* @parameters:
*     - Number value: Latitude or longitude.
* @return: String
*/
function formatCoordinate(value) {
    return String(value);
}

/**
* Method Name: formatDistance
* @author: Tharun N
* @description: Distance as "N m" under 1 km, otherwise "N.N km".
* @parameters:
*     - Number meters: Distance in meters.
* @return: String
*/
function formatDistance(meters) {
    return meters < 1000 ? `${Math.round(meters)} m` : `${(meters / 1000).toFixed(1)} km`;
}

/**
* Method Name: distanceMeters
* @author: Tharun N
* @description: Straight-line distance between two points (Haversine).
* @parameters:
*     - Number lat1, lon1: First point.
*     - Number lat2, lon2: Second point.
* @return: Number distance in meters.
*/
function distanceMeters(lat1, lon1, lat2, lon2) {
    const toRadians = (degrees) => (degrees * Math.PI) / 180;
    const dLat = toRadians(lat2 - lat1);
    const dLon = toRadians(lon2 - lon1);
    const a =
        Math.sin(dLat / 2) ** 2 +
        Math.cos(toRadians(lat1)) * Math.cos(toRadians(lat2)) * Math.sin(dLon / 2) ** 2;
    return 2 * EARTH_RADIUS_METERS * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}