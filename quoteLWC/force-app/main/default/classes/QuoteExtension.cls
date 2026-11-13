public class QuoteExtension {
    public Quote quote { get; set; }
    public String paymentTerms { get; set; }
    
    public QuoteExtension(ApexPages.StandardController controller) {

        this.quote = (Quote) controller.getRecord();
        paymentTerms = 'Net 30';
        
        //Fetch the Payment Terms from the related Account
        if (quote.AccountId != null) {
            Account acc = [SELECT Payment_Terms_SAP__c FROM Account WHERE Id = :quote.AccountId LIMIT 1];
            paymentTerms = acc?.Payment_Terms_SAP__c ?? 'Net 30 with credit approval.';           
        }
    }
}
