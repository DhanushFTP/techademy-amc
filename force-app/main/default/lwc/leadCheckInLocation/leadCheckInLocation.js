/******************************************************************
 * Component Name : leadCheckInLocation
 * Company        : Fingertip Technologies Pvt Ltd
 * Created Date   : 06-11-2026
 * @description   : Lead Check In / Check Out. Same screen and GPS
 *                  reading as the Account check-in (checkInLocation), but
 *                  saves to Lead Check In (Lead_Check_In__c) through
 *                  LeadCheckInController. The distance check against the
 *                  lead's Lead Geo Location (custom label
 *                  Check_In_Max_Distance_Meters, 1000 m) is done on the
 *                  server. LeadCheckInController returns
 *                  { success, message } instead of throwing, so failed
 *                  attempts are logged on the server. GPS errors on the
 *                  phone are logged with logClientError.
 * @author        : Tharun N
 * Used By        : - leadCheckInWrapper (Aura): Lead "Check In" quick
 *                    action (phone)
 * Apex           : LeadCheckInController
 * Change Log:
 * -----------------------------------------------------------------------------
 * Ver | Author          | Date       | Description
 * -----------------------------------------------------------------------------
 * 1.0 | Tharun N        | 06-11-2026 | Initial version (500 m check-in
 *     |                 |            | distance)
 * 1.1 | Tharun N        | 16-11-2026 | Comments only: the distance is now
 *     |                 |            | 1000 m from Check_In_Max_Distance_Meters
 *     |                 |            | (set in LeadCheckInController).
 *     |                 |            | Standard header. No code change.
 * -----------------------------------------------------------------------------
 ******************************************************************/
import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import checkIn from '@salesforce/apex/LeadCheckInController.checkIn';
import checkOut from '@salesforce/apex/LeadCheckInController.checkOut';
import getActiveCheckIn from '@salesforce/apex/LeadCheckInController.getActiveCheckIn';
import logClientError from '@salesforce/apex/LeadCheckInController.logClientError';

export default class LeadCheckInLocation extends LightningElement {
    @api recordId;
    @track activeCheckIn = null;
    @track isLoading = true;
    checkOutNotes = '';

    connectedCallback() {
        this.loadActiveCheckIn();
    }

    get checkInTimeFormatted() {
        if (this.activeCheckIn && this.activeCheckIn.Check_In_Time__c) {
            return new Date(this.activeCheckIn.Check_In_Time__c).toLocaleString();
        }
        return '';
    }

    loadActiveCheckIn() {
        this.isLoading = true;
        getActiveCheckIn({ leadId: this.recordId })
            .then((result) => {
                this.activeCheckIn = result;
            })
            .catch((error) => {
                console.error('Error loading active lead check-in:', error);
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleNotesChange(event) {
        this.checkOutNotes = event.target.value;
    }

    // ── Get current GPS position using browser Geolocation API (same as the Account check-in) ──
    _getCurrentPosition() {
        return new Promise((resolve, reject) => {
            if (!navigator.geolocation) {
                reject(new Error('Location is not supported on this device. Please enable location services.'));
                return;
            }
            navigator.geolocation.getCurrentPosition(
                (position) => resolve(position),
                (err) => {
                    let msg = 'Unable to get your location. ';
                    if (err.code === 1) {
                        msg += 'Please allow location access for the Salesforce app in your phone Settings.';
                    } else if (err.code === 2) {
                        msg += 'Location unavailable. Please check GPS is enabled.';
                    } else {
                        msg += 'Request timed out. Please try again.';
                    }
                    reject(new Error(msg));
                },
                { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 }
            );
        });
    }

    // ── Check In ──
    handleCheckIn() {
        if (!this.recordId) {
            this.showToast('Error', 'No recordId — cannot check in.', 'error', 'sticky');
            return;
        }

        this.isLoading = true;
        this._getCurrentPosition()
            .then(({ coords }) => {
                return checkIn({
                    leadId: this.recordId,
                    latitude: coords.latitude,
                    longitude: coords.longitude
                });
            })
            .then((result) => {
                if (result && result.success) {
                    this.showToast('Checked In', 'Your check-in has been recorded.', 'success');
                    this.loadActiveCheckIn();
                } else {
                    // Already logged on the server
                    this.showToast('Check-In Failed', result?.message || 'Check-in failed. Please try again.', 'error', 'sticky');
                    this.isLoading = false;
                }
            })
            .catch((error) => {
                const msg = error.body?.message || error.message || JSON.stringify(error);
                this.showToast('Check-In Failed', msg, 'error', 'sticky');
                if (!error.body) {
                    logClientError({ leadId: this.recordId, errorMessage: msg });
                }
                this.isLoading = false;
            });
    }

    // ── Check Out ──
    handleCheckOut() {
        if (!this.activeCheckIn) {
            this.showToast('Error', 'No active check-in found.', 'error');
            return;
        }

        this.isLoading = true;
        this._getCurrentPosition()
            .then(({ coords }) => {
                return checkOut({
                    checkInId: this.activeCheckIn.Id,
                    latitude: coords.latitude,
                    longitude: coords.longitude,
                    notes: this.checkOutNotes
                });
            })
            .then((result) => {
                if (result && result.success) {
                    this.showToast('Checked Out', 'Your check-out has been recorded.', 'success');
                    this.activeCheckIn = null;
                    this.checkOutNotes = '';
                } else {
                    // Already logged on the server
                    this.showToast('Check-Out Failed', result?.message || 'Check-out failed. Please try again.', 'error', 'sticky');
                }
                this.isLoading = false;
            })
            .catch((error) => {
                const msg = error.body?.message || error.message || JSON.stringify(error);
                this.showToast('Check-Out Failed', msg, 'error', 'sticky');
                if (!error.body) {
                    logClientError({ leadId: this.recordId, errorMessage: msg });
                }
                this.isLoading = false;
            });
    }

    showToast(title, message, variant, mode = 'dismissable') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
    }
}