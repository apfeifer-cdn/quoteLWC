public class QuoteLogoExtension {
    public Quote currentQuote { get; private set; } // Expose the Quote object
    public String logoStaticResource { get; private set; }

    // Constructor that accepts a StandardController object
    public QuoteLogoExtension(ApexPages.StandardController controller) {
        // Get the Quote record from the StandardController
        currentQuote = (Quote)controller.getRecord();

        // Ensure that the Quote record is fully populated
        currentQuote = [SELECT Id, QuoteNumber, Account.Name FROM Quote WHERE Id = :currentQuote.Id LIMIT 1];

        logoStaticResource = getLogoResource(currentQuote?.Account?.Name) ?? null;
    }

    // Default constructor (no longer needed for this use case, so it's optional)
    public QuoteLogoExtension() {
    }

    // Helper method to get the logo based on account name
    private String getLogoResource(String accountName) {
        // Map account names to static resource names
        Map<String, String> logoMap = new Map<String, String>{
            'Staples Promotional Products' => 'Logo_Staples',
            'BDA' => 'Logo_BDA',
            'Halo Branded Solutions, Inc.' => 'Logo_Halo',
            '3Point Brand Management' => 'Logo_3PointBrandManagement',
            'Acres, Inc' => 'Logo_NZone',
            'Adcentives West' => 'Logo_Adcentives_West',
            'AD-Vantage, Inc' => 'Logo_Advantage', 
            'AHHA Group, Inc' => 'Logo_AHHA',
            'Ame & LuLu' => 'Logo_AmeAndLulu',
            'American Solutions for Business' => 'Logo_American_Solutions_for_Business',
            'Bergman Incentives' => 'Logo_Bergman',
            'BI' => 'Logo_BI',
            'Black Rock Business Solutions, LLC' => 'Logo_BlackRock', 
            'Brand Aid' => 'Logo_BrandAid', 
            'Boundless Network' => 'Logo_Boundless_Network',
            'BT Promotions' => 'Logo_StadiumGraphics',
            'Dogwood Canyon' => 'Logo_DogwoodCanyon',
            'Eskimo Joe\'s Promotional Products' => 'Logo_EskimoJoes',
            'Flag and Anthem' => 'Logo_FlagAndAnthem',
            'Flywheel Brands Inc' => 'Logo_Flywheel_Brands_Inc',
            'Geiger Bros' => 'Logos_Geiger_Bros',
            'Gorfam Marketing, Inc.' => 'Logo_Gorfam',
            'Grandstand' => 'Logo_Grandstand', 
            'Grapevine' => 'Logo_Grapevine',
            'Grunt Style' => 'Logo_GruntStyle',
            'Hillary\'s' => 'Logo_Hillarys',
            'Huntsman Holdings, LLC' => 'Logo_BigCedarLodge',
            'Johnny Morris\' Ozarks Heritage Preserve' => 'Logo_JohnnyMorris', 
            'Juice Marketing' => 'Logo_JuiceMarketing', 
            'Landmark Graphics' => 'Logo_Landmark_Graphics',
            'MAS Inc.' => 'Logo_MAS_Inc',
            'Michael Walker' => 'Logo_Michael_Walker',
            'MPC Louisville Promotions' => 'Logo_MPC_Louisville_Promotions',
            'My Brand Promo' => 'Logo_MyBrandPromo',
            'Nicole Brayden Gifts LLC' => 'Logo_Nicole_Brayden_Gifts_LLC',
            'Norscot' => 'Logo_Norscot',
            'Ozark Mills, LLC' => 'Logo_OzarkMill',
            'Performance Award Center' => 'Logo_Performance_Award_Center',
            'Piston Driven LLC' => 'Logo_PistonDriven',
            'Prairy, LLC' => 'Logo_Prairy_LLC',
            'Proforma LaDuke' => 'Logo_Proforma',
            'Proforma InMotion' => 'Logo_Proforma',
            'Proforma Branded Media' => 'Logo_Proforma',
            'Proforma Unique Promotional Concepts' => 'Logo_Proforma',
            'Proforma Kissel Marketing LLC' => 'Logo_Proforma',
            'Proforma Good Wood Marketing' => 'Logo_Proforma',
            'RCSolutions' => 'Logo_RCSolutions',
            'RIO Design, INK' => 'Logo_RIO_Design_INK',
            'Sales Central, INC.' => 'Logo_Sales_Central_INC',
            'Sales Central Inc.' => 'Logo_Sales_Central_INC',
            'Scoby Brothers' => 'Logo_ScobyBrothers',
            'ScreenWorks USA' => 'Logo_Screenworks',
            'SS Designs' => 'Logo_SSDesign',
            'Standout Solutions' => 'Logo_StandoutSolutions',
            'The Specialized Marketing Group, Inc' => 'Logo_The_Specialized_Marketing_Group_Inc',
            'Varsity Apparel' => 'Logo_Varsity_Apparel',
            'Varsity Team Apparel' => 'Logo_Varsity_Apparel',
            'Zinc USA Inc' => 'Logo_Zinc'
            // No default entry here since we want no logo for unknown accounts
            };

        // Return the corresponding logo static resource or null
        return logoMap.containsKey(accountName) ? logoMap.get(accountName) : null;
    }
}
