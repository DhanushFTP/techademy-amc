({
    /**
     * loadPhoneNumbers
     * Calls MCubeSoftphoneController.getPhoneNumbers() to retrieve all
     * phone-type field values from the current record.
     * Populates the phoneList attribute so the agent can choose which number
     * to dial.
     *
     * @param {Object} component - Aura component reference
     * @param {Object} event     - Aura event reference
     * @param {Object} helper    - Aura helper reference (self)
     */
    loadPhoneNumbers: function (component, event, helper) {
        component.set('v.isLoading', true);

        var action = component.get('c.getPhoneNumbers');
        action.setParams({
            recordId: component.get('v.recordId')
        });

        action.setCallback(this, function (response) {
            component.set('v.isLoading', false);
            var state = response.getState();

            if (state === 'SUCCESS') {
                var phones = response.getReturnValue();
                if (phones && phones.length > 0) {
                    component.set('v.phoneList', phones);
                    // Pre-select the first number for convenience
                    component.set('v.selectedPhone', phones[0]);
                } else {
                    component.set('v.errorMessage', 'No phone numbers found on this record.');
                    helper.showToast(component,
                        'No Phone Numbers Found',
                        'No phone numbers are available on this record.',
                        'warning');
                }
            } else if (state === 'ERROR') {
                var errors  = response.getError();
                var message = 'Unknown error';
                if (errors && errors[0] && errors[0].message) {
                    message = errors[0].message;
                }
                component.set('v.errorMessage', 'Could not load phone numbers: ' + message);
                helper.showToast(component, 'Error',
                    'Could not load phone numbers: ' + message, 'error');
                console.error('mcubeClick2Call – loadPhoneNumbers error: ' + message);
            } else {
                component.set('v.errorMessage', 'Something went wrong while loading phone numbers.');
                helper.showToast(component, 'Error',
                    'Something went wrong while loading phone numbers.', 'error');
            }
        });

        $A.enqueueAction(action);
    },

    /**
     * dialSelectedNumber
     * Calls MCubeSoftphoneController.clickToCall() to place the outbound call
     * through the MCube outbound API directly (no softphone-widget round trip).
     * Toasts the returned { success, message } and closes the quick action.
     *
     * @param {Object} component - Aura component reference
     * @param {Object} event     - Aura event reference
     * @param {Object} helper    - Aura helper reference (self)
     */
    dialSelectedNumber: function (component, event, helper) {
        var selectedPhone = component.get('v.selectedPhone');
        var recordId      = component.get('v.recordId');

        component.set('v.isLoading', true);

        var action = component.get('c.clickToCall');
        action.setParams({
            recordId       : recordId,
            customerNumber : selectedPhone
        });

        action.setCallback(this, function (response) {
            component.set('v.isLoading', false);
            var state = response.getState();

            if (state === 'SUCCESS') {
                var result = response.getReturnValue();
                if (result && result.success) {
                    helper.showToast(component, 'Call Initiated',
                        'Dialing ' + selectedPhone + ' via MCube.', 'success');
                } else {
                    helper.showToast(component, 'Call Failed',
                        (result && result.message) || 'Unable to place the call.', 'error');
                }
            } else if (state === 'ERROR') {
                var errors  = response.getError();
                var message = (errors && errors[0] && errors[0].message)
                    ? errors[0].message : 'Unknown error';
                helper.showToast(component, 'Call Failed', message, 'error');
                console.error('mcubeClick2Call – clickToCall error: ' + message);
            }

            // Close the quick action after a brief delay so the agent sees the toast
            window.setTimeout($A.getCallback(function () {
                helper.closeQuickAction();
            }), 1500);
        });

        $A.enqueueAction(action);
    },

    /**
     * showToast
     * Utility: fires a Lightning force:showToast event with the given
     * title, message, and type (success / error / warning / info).
     *
     * @param {Object} component - Aura component reference
     * @param {String} title     - Toast title
     * @param {String} message   - Toast body text
     * @param {String} type      - Toast variant: success | error | warning | info
     */
    showToast: function (component, title, message, type) {
        var toastEvent = $A.get('e.force:showToast');
        if (toastEvent) {
            toastEvent.setParams({
                title  : title,
                message: message,
                type   : type
            });
            toastEvent.fire();
        }
    },

    /**
     * closeQuickAction
     * Fires the force:closeQuickAction event to dismiss the quick-action
     * modal after a call is placed or cancelled.
     */
    closeQuickAction: function () {
        var closeEvent = $A.get('e.force:closeQuickAction');
        if (closeEvent) {
            closeEvent.fire();
        }
    }
})