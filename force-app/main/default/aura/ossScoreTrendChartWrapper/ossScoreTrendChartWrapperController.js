({
    doInit: function (component, event, helper) {
        var recordId = component.get("v.recordId");
        if (recordId) {
            component.set("v.vfUrl", "/apex/OSSScoreTrendChart?id=" + recordId);
        }
    }
})