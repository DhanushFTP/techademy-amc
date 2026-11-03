import { LightningElement, api, track }      from 'lwc';
import { ShowToastEvent }                    from 'lightning/platformShowToastEvent';
import createCheckIn                         from '@salesforce/apex/CheckInController.createCheckIn';
import performCheckOut                       from '@salesforce/apex/CheckInController.performCheckOut';
import getActiveCheckIn                      from '@salesforce/apex/CheckInController.getActiveCheckIn';
import logClientError                        from '@salesforce/apex/CheckInController.logClientError';

export default class CheckInLocation extends LightningElement {
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
        getActiveCheckIn({ accountId: this.recordId })
            .then(result => {
                this.activeCheckIn = result;
            })
            .catch(error => {
                console.error('Error loading active check-in:', error);
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    handleNotesChange(event) {
        this.checkOutNotes = event.target.value;
    }

    // ── Get current GPS position using browser Geolocation API ──
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
            return this.showToast('Error', 'No recordId — cannot check in.', 'error', 'sticky');
        }

        this.isLoading = true;
        this._getCurrentPosition()
            .then(({ coords }) => {
                return createCheckIn({
                    accountId: this.recordId,
                    latitude:  coords.latitude,
                    longitude: coords.longitude
                });
            })
            .then(() => {
                this.showToast('Checked In', 'Your check-in has been recorded.', 'success');
                this.loadActiveCheckIn();
            })
            .catch(error => {
                const msg = error.body?.message || error.message || JSON.stringify(error);
                this.showToast('Check-In Failed', msg, 'error', 'sticky');
                if (!error.body) {
                    logClientError({ accountId: this.recordId, errorMessage: msg });
                }
                this.isLoading = false;
            });
    }

    // ── Check Out ──
    handleCheckOut() {
        if (!this.activeCheckIn) {
            return this.showToast('Error', 'No active check-in found.', 'error');
        }

        this.isLoading = true;
        this._getCurrentPosition()
            .then(({ coords }) => {
                return performCheckOut({
                    checkInId: this.activeCheckIn.Id,
                    latitude:  coords.latitude,
                    longitude: coords.longitude,
                    notes:     this.checkOutNotes
                });
            })
            .then(() => {
                this.showToast('Checked Out', 'Your check-out has been recorded.', 'success');
                this.activeCheckIn = null;
                this.checkOutNotes = '';
                this.isLoading = false;
            })
            .catch(error => {
                const msg = error.body?.message || error.message || JSON.stringify(error);
                this.showToast('Check-Out Failed', msg, 'error', 'sticky');
                if (!error.body) {
                    logClientError({ accountId: this.activeCheckIn?.Id, errorMessage: msg });
                }
                this.isLoading = false;
            });
    }

    showToast(title, message, variant, mode = 'dismissable') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
    }
}