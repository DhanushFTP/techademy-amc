public class ContactTriggerHandler {
	// method to check if there is any account already associated with the lead, if yes then lead will be assigned to the account Manager
    // Author -: Vaibhav Kumar Chauhan
    // Organisation -: Utilitarian Labs Pvt. Ltd.
    // Date of Creation -: 28-Dec-2023
    // Last Updated on-: 28-Dec-2023
    // 
    public static void assignContactsToAM(List<Contact> conList){
        try{           
            System.debug('conList==> ' + conList);
            //List<Contact> leadsToBeAssignedToAM = new List<Contact>();
            Map<Id, List<Contact>> contactsByAccountId = new Map<Id, List<Contact>>();
            for(Contact conRec : conList){
                if(conRec.AccountId != null && (!contactsByAccountId.containsKey(conRec.AccountId))){
                    contactsByAccountId.put(conRec.AccountId, new List<Contact>{conRec});
                }else if(conRec.AccountId != null && contactsByAccountId.containsKey(conRec.AccountId)){
                    contactsByAccountId.get(conRec.AccountId).add(conRec);
                }
            }
            System.debug('contactsByAccountId==>' + contactsByAccountId);
            List<Account> accList = [SELECT Id, OwnerId, Name FROM Account WHERE Id IN: contactsByAccountId.keySet()];
            System.debug('accList==> ' + accList);
            Map<Id, Id> ownerIdByAccountId = new Map<Id,Id>();
            for(Account accRec : accList){
                if(!ownerIdByAccountId.containsKey(accRec.Id)){
                    ownerIdByAccountId.put(accRec.Id, accRec.OwnerId);
                }
            }
            for(Id accId : contactsByAccountId.keySet()){
                for(Contact leadRec : contactsByAccountId.get(accId)){
                    leadRec.OwnerId = ownerIdByAccountId.get(accId);
                    //leadsToBeAssignedToAM.add(leadRec);
                }
            }
            /*if(!leadsToBeAssignedToAM.isEmpty()){
				update leadsToBeAssignedToAM;
                System.debug('leadsToBeAssignedToAM==> ' + leadsToBeAssignedToAM);
            }*/
        }
        catch(exception e){
            System.debug('Error Message -- ' + e.getMessage() + ' at Line Number -- ' + e.getLineNumber());
        }
    }
    public static void addJtToTitleAndTitleToJt(List<Contact> conList){
        for(Contact con : conList){
            if(con.Title != null && con.Job_Title__c == null){
                con.Job_Title__c = con.Title;
            }else if(con.Title == null && con.Job_Title__c != null){
                con.Title = con.Job_Title__c;
            }
            if(con.MobilePhone != null && con.Phone == null){
                con.Phone = con.MobilePhone;
            }else if(con.MobilePhone == null && con.Phone != null){
				con.MobilePhone = con.Phone;                
            }
        }
    }
}