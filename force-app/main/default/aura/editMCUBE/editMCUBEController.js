({
    closeModal: function (component, event, helper) {
        var recordId = component.get('v.recordId');

        if (recordId) {
            // ✅ Edit — go back to the record detail page
            var navService = component.find('navService');
            var pageRef = {
                type      : 'standard__recordPage',
                attributes: {
                    recordId    : recordId,
                    actionName  : 'view'
                }
            };

            // Use lightning:navigation to navigate
            $A.get('e.force:navigateToURL') ;

            // Preferred way in Aura — use force:navigateToSObject
            var navEvt = $A.get('e.force:navigateToSObject');
            if (navEvt) {
                navEvt.setParams({
                    recordId   : recordId,
                    slideDevName: 'detail'
                });
                navEvt.fire();
            }
        } else {
            // Fallback — go to object home if no recordId for some reason
            var homeEvt = $A.get('e.force:navigateToObjectHome');
            if (homeEvt) {
                homeEvt.setParams({ scope: 'MCube_Configuration__c' });
                homeEvt.fire();
            }
        }
    }
})