public class QuotePDFControllerExtension {
    public Quote quote { get; set; }

    // Constructor that accepts the Standard Controller
    public QuotePDFControllerExtension(ApexPages.StandardController controller) {
        this.quote = (Quote)controller.getRecord(); // Cast the record to Quote
    }

    public PageReference generateQuotePDF() {
        return generatePdfFromTemplate('CDN_Quote_Page');
    }

    public PageReference generateOriginalQuotePDF() {
        return generatePdfFromTemplate('Quote_Page');
    }

    private PageReference generatePdfFromTemplate(String template) {
        PageReference pdfPage = new PageReference('/apex/' + template);
        pdfPage.getParameters().put('id', quote.Id);
        
        // Step 2: Generate the PDF as a Blob
        Blob pdfBlob;
        try {
            if(!Test.isRunningTest()){
                pdfBlob = pdfPage.getContentAsPDF();
            }
            else{
                pdfBlob = Blob.valueOf('Test');
            }
            
        } catch (VisualforceException e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Error generating PDF content: ' + e.getMessage()));
            return null; // Stay on the same page if there's an error
        }
        
        // Step 3: Create a new ContentVersion record to attach to the Quote
        ContentVersion contentVersion = new ContentVersion();
        contentVersion.Title = 'Quote_' + quote.Id + '.pdf';
        contentVersion.PathOnClient = 'Quote_' + quote.Id + '.pdf';
        contentVersion.VersionData = pdfBlob;
        contentVersion.IsMajorVersion = true;
        contentVersion.Origin = 'H'; // Human origin
        
        // Insert the ContentVersion
        try {
            insert contentVersion;
        } catch (DmlException e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Error saving PDF: ' + e.getMessage()));
            return null; // Stay on the same page if there's an error
        }

        // Step 4: Link the ContentVersion to the Quote using ContentDocumentLink
        ContentDocument doc = [SELECT Id FROM ContentDocument WHERE LatestPublishedVersionId = :contentVersion.Id LIMIT 1];
        
        ContentDocumentLink link = new ContentDocumentLink();
        link.ContentDocumentId = doc.Id; // Set the ContentDocumentId to the one just created
        link.LinkedEntityId = quote.Id;   // Link to the Quote
        link.ShareType = 'V';              // Set share type to Viewer

        // Insert the ContentDocumentLink
        try {
            insert link;
        } catch (DmlException e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Error linking PDF to Quote: ' + e.getMessage()));
            return null; // Stay on the same page if there's an error
        }

        PageReference download = new PageReference('/sfc/servlet.shepherd/version/download/' + contentVersion.Id);
        download.setRedirect(true);
        return download;
    }

    // Method to redirect to the PDF view
    public PageReference generatePDFRedirect() {
        // Ensure this URL points to the correct PDF page
        PageReference pdfPage = new PageReference('/apex/CDN_Quote_Page?id=' + quote.Id);
        pdfPage.setRedirect(true);
        return pdfPage;
    }

    // Getter for quote
    public Quote getQuote() {
        return quote;
    }
}
