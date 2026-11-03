public class LeadTriggerHandler {
    
    // method to check if there is any account already associated with the lead, if yes then lead will be assigned to the account Manager
    // Author -: Vaibhav Kumar Chauhan
    // Organisation -: Utilitarian Labs Pvt. Ltd.
    // Date of Creation -: 29-Nov-2023
    // Last Updated on-: 29-Nov-2023
 
    public static void assignLeadsToAM(List<Lead> leadList){
        try{           
            System.debug('leadList==> ' + leadList);
            //List<Lead> leadsToBeAssignedToAM = new List<Lead>();
              List<LeadAssignmentBasedOnProductCategory__mdt> ledAss = LeadAssignmentBasedOnProductCategory__mdt.getAll().values();
            String UserNameOfYaksha;
             String UserNameOfTECHADEMY;
            for(LeadAssignmentBasedOnProductCategory__mdt leadAssignToUser : ledAss){
                if(leadAssignToUser.Label == 'YAKSHA'){
                    UserNameOfYaksha = leadAssignToUser.USERNAME__c;
                }
                else if(leadAssignToUser.Label == 'TECHADEMY'){
                    UserNameOfTECHADEMY = leadAssignToUser.USERNAME__c;
                }
            }
            String YakshaId;
            String TechAdmeyId;
            List<User> userList = [SELECT Id,Name,UserName FROM User WHERE UserName =:UserNameOfYaksha OR UserName =:UserNameOfTECHADEMY];
            System.debug('userList==> ' + userList);
            for(User userRec : userList){
                if(userRec.UserName == UserNameOfYaksha){
                    YakshaId = userRec.Id;
                    System.debug('inside Yaksha Block');
                }else if(userRec.UserName == UserNameOfTECHADEMY){
                    TechAdmeyId = userRec.Id;
                    System.debug('inside Techademy Block');
                }
            }
            System.debug('YakshaId==> ' + YakshaId);
            System.debug('TechAdmeyId==> ' + TechAdmeyId);
            Map<Id, List<Lead>> leadsByAccountId = new Map<Id, List<Lead>>();
            for(Lead ldRec : leadList){
                if(ldRec.AccountId__c != null && !(leadsByAccountId.containsKey(ldRec.AccountId__c))){
                    leadsByAccountId.put(ldRec.AccountId__c, new List<Lead>{ldRec});
                }else if(ldRec.AccountId__c != null && leadsByAccountId.containsKey(ldRec.AccountId__c)){
                    leadsByAccountId.get(ldRec.AccountId__c).add(ldRec);
                }else if(ldRec.AccountId__c == null && ldRec.Product_Category__c != null){
                    if(ldRec.Product_Category__c == 'YAKSHA'){
                        ldRec.OwnerId = YakshaId;
                    }else if(ldRec.Product_Category__c == 'TECHADMEY'){
                        ldRec.OwnerId = TechAdmeyId;
                    }
                }
            }
            System.debug('leadsByAccountId==>' + leadsByAccountId);
            List<Account> accList = [SELECT Id, OwnerId, Name FROM Account WHERE Id IN: leadsByAccountId.keySet()];
            System.debug('accList==> ' + accList);
            Map<Id, Id> ownerIdByAccountId = new Map<Id,Id>();
            for(Account accRec : accList){
                if(!ownerIdByAccountId.containsKey(accRec.Id)){
                    ownerIdByAccountId.put(accRec.Id, accRec.OwnerId);
                }
            }
            for(Id accId : leadsByAccountId.keySet()){
                for(Lead leadRec : leadsByAccountId.get(accId)){
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
    
    public static void addJtToTitleAndTitleToJt(List<Lead> leadList){
        for(Lead ld : leadList){
            if(ld.Title != null && ld.Job_Title__c == null){
                ld.Job_Title__c = ld.Title;
            }else if(ld.Title == null && ld.Job_Title__c != null){
                ld.Title = ld.Job_Title__c;
            }
        }
    }
}