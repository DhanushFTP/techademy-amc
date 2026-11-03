({
    doInit : function(component, event, helper) {
      const rid = component.get("v.recordId") || "<<null>>";
      const toast = $A.get("e.force:showToast");
      toast.setParams({
        title:   "Aura DEBUG Id",
        message: rid,
        variant: "info",
        mode:    "sticky"
      });
      toast.fire();
    }
  })