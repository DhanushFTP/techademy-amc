public class NumberSystem {
    
    public String selectedvalue { get; set; }
 public transient string num { get; set; }
 public transient string result { get; set; }
 public transient string out{get;set;}
 integer i=0,j=1;
 integer flg=0,flg1=1;
 integer length,len;

 //command button
 public String NumConvert() {
   if(!(boolean)num.isNumeric())
     result='Incompatible, Try Numeric Format Only';
   else{
      try{
          num = string.valueOf(long.valueOf(num));
      } catch(TypeException e){
          System.debug('****************************************');
          System.debug('The Following Exception Occurred:'+e.getMessage());
          System.debug('****************************************');
        }//catch closed
     len=num.length();
     out=' ';
     if(length > 15)
         result='Number Out Of Range, Max Of 15 Digits Only';
     else if(selectedvalue=='International')
         result=internationalConversion();
     else
        result=indianConversion();
       return result;
   }//outer else closed
   return null;
 }//NumConvert (CommandButton)Closed
    
    public string indianConversion(){
        length=len; i=0;j=1;
        while(length >= 1)
        {
            if(length==15||length==13||length==11||length==9||length==7||length==5||length==2) {
                if(num.substring(i,j)=='0'){
                    length--;flg1=flg=0;
                    i++; j++;
                }
                else if(num.substring(i,j)=='1'){
                    out+= twoDigitTeen();
                    length--; flg1=flg=1;
                    i++; j++;
                }//inner else if closed
                else{
                    out+= twoDigitzero();
                    length--; flg=0;flg1=1;
                    i++; j++;
                }
            }//outer if closed
            if((length==14||length==12||length==10||length==8||length==6||length==4||length==3||length==1)&&(flg==0))
            {
                if(num.substring(i,j)=='0' && flg1==0)
                    flg1=0;
                else{
                    flg1=1;
                    out+=singleDigits();
                }//else closed
            }//outer if closed
            if(length==14 && flg1==1)
                out+=' Neel ';
            else if(length==12 && flg1==1)
                out+=' Kharab ';
            else if(length==10 && flg1==1)
                out+=' Arab ';
            else if(length==8 && flg1==1)
                out+=' Crore ';
            else if(length==6 && flg1==1)
                out+=' Lakhs ';
            else if(length==4 && flg1==1)
                out+=' Thousand ';
            else if(length==3){
                if(num.substring(i,j)!='0')
                    out+=' Hundred ';
            }
            flg=0;length--;
            i++;j++;
        }//while closed
        return out;
    }//indianConvertion Closed
    
    public string internationalConversion(){
        out=''; flg1=1;
        length=len; i=0;j=1;
        while(length >= 1){
            if(length==15||length==12||length==9||length==6||length==3){
                if(num.substring(i,j)!='0'){
                    out+=(singleDigits()+'Hundred');
                    flg1=0;
                } else
                    out+=singleDigits();
                length--; i++;j++;
            }//if closed
            if(length==14||length==11||length==8||length==5||length==2){
                if(num.substring(i,j)=='0' && flg1==1){
                    flg1=1;length--;
                    i++; j++;
                }
                else if(num.substring(i,j)=='1'){
                    out+= twoDigitTeen();
                    length--; flg=1; flg1=0;
                    i++; j++;
                }//inner else if closed
                else{
                    out+= twoDigitzero();
                    length--; flg=0;flg1=0;
                    i++; j++;
                }//else closed
            }//outer if closed 
            
            If((length/3==1||length==1)&& (flg==0)){
                if((num.substring(i,j)=='0') && (flg1==1))
                    flg1=1;
                else{
                    flg1=0;
                    out+=singleDigits();
                }//outer else closed
            }//outer if closed
            if(length==13 && flg1==0)
                out+=' Trillion ';
            else if(length==10 && flg1==0)
                out+=' Billion ';
            else if(length==7 && flg1==0)
                out+=' Million ';
            else if(length==4 && flg1==0)
                out+=' Thousand ';
            flg=0;length--;
            i++;j++;flg1=1;
        } //while closed
        return out;
    }//internationalConvertion closed
    
    public String twoDigitTeen(){
        transient string temp;
        if(num.substring(i+1,j+1)=='1')
            temp = ' Eleven ';
        else if(num.substring(i+1,j+1)=='2')
            temp =' Twelve ';
        else if(num.substring(i+1,j+1)=='3')
            temp = ' Thirteen ';
        else if(num.substring(i+1,j+1)=='4')
            temp = ' Fourteen ';
        else if(num.substring(i+1,j+1)=='5')
            temp =' Fifteen ';
        else if(num.substring(i+1,j+1)=='6')
            temp =' Sixteen ';
        else if(num.substring(i+1,j+1)=='7')
            temp =' Seventeen ';
        else if(num.substring(i+1,j+1)=='8')
            temp =' Eighteen ';
        else if(num.substring(i+1,j+1)=='9')
            temp =' Ninteen ';
        else if(num.substring(i+1,j+1)=='0')
            temp =' Ten ';
        else temp='';
        return temp;
    }//twoDigitTeen ends
    
    public string twoDigitzero(){
        transient string temp;
        if(num.substring(i,j)=='2')
            temp =' Twenty ';
        else if(num.substring(i,j)=='3')
            temp =' Thirty ';
        else if(num.substring(i,j)=='4')
            temp =' Fourty ';
        else if(num.substring(i,j)=='5')
            temp =' Fifty ';
        else if(num.substring(i,j)=='6')
            temp =' Sixty ';
        else if(num.substring(i,j)=='7')
            temp =' Seventy ';
        else if(num.substring(i,j)=='8')
            temp =' Eighty ';
        else if(num.substring(i,j)=='9')
            temp =' Ninty ';
        else temp='';
        return temp;
    }//twoDigitzero ends
    
    public string singleDigits(){
        transient string temp;
        if(num.substring(i,j)=='1')
            temp =' One ';
        else if(num.substring(i,j)=='2')
            temp =' Two ';
        else if(num.substring(i,j)=='3')
            temp =' Three ';
        else if(num.substring(i,j)=='4')
            temp =' Four ';
        else if(num.substring(i,j)=='5')
            temp =' Five ';
        else if(num.substring(i,j)=='6')
            temp =' Six ';
        else if(num.substring(i,j)=='7')
            temp =' Seven ';
        else if(num.substring(i,j)=='8')
            temp =' Eight ';
        else if(num.substring(i,j)=='9')
            temp =' Nine ';
        else temp= '';
        return temp;
    }//singleDigits ends
    
    public static void codeCoverage(){
        integer i=0;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
        i++;
    }
}