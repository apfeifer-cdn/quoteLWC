@IsTest
private class QuoteCostServiceTest {

    private static final List<Integer> TIERS = new List<Integer>{ 72, 144, 288, 432, 576, 1008 };

    private class Fixture {
        Product2 baseStyle;
        Product2 mainDecoration;
        Product2 secondLocation;
        Product2 uncosted;
        Product2 additionalOnly;
        mfg__c manufacturer;
    }

    /** Mexico Quick Turn setup taken from the 2026 costing sheet for style 1100PR. */
    private static Fixture buildFixture() {
        Fixture f = new Fixture();
        f.baseStyle = new Product2(Name = 'Polyester Boonie', ProductCode = 'T-1100PR',
            IsActive = true, Blank_FOB__c = 6.2737);
        f.mainDecoration = new Product2(Name = 'Flat Embroidery', ProductCode = 'T-FlatEmb',
            IsActive = true, Main_Decoration_Cost__c = 0.70, Additional_Location_Cost__c = 0.49);
        f.secondLocation = new Product2(Name = 'Sublimation Patch', ProductCode = 'T-SubPatch',
            IsActive = true, Main_Decoration_Cost__c = 0.82);
        f.uncosted = new Product2(Name = 'UPC Sticker', ProductCode = 'T-Upc', IsActive = true);
        f.additionalOnly = new Product2(Name = 'Visor Rope', ProductCode = 'T-Rope',
            IsActive = true, Additional_Location_Cost__c = 0.25);
        insert new List<Product2>{ f.baseStyle, f.mainDecoration, f.secondLocation, f.uncosted, f.additionalOnly };

        f.manufacturer = new mfg__c(
            Name = 'Test MLMX QT',
            Duty_Rate__c = 0, MPF_Rate__c = 0, Insurance_Rate__c = 1.5, Finance_Rate__c = 3,
            Broker_Fee__c = 0.01, Freight__c = 0.05, WH_HDL__c = 0.01,
            Marketing_Fee__c = 0.02, Compliance_Fee__c = 0.01
        );
        insert f.manufacturer;

        insert new List<Manufacturer_Upcharge__c>{
            upcharge(f.manufacturer.Id, 432, 575, 'Multiplier', 1.05),
            upcharge(f.manufacturer.Id, 288, 431, 'Multiplier', 1.10),
            upcharge(f.manufacturer.Id, 144, 287, 'Multiplier', 1.20),
            upcharge(f.manufacturer.Id, 72, 143, 'Multiplier', 1.45)
        };
        return f;
    }

    private static Manufacturer_Upcharge__c upcharge(Id manufacturerId, Integer lower, Integer upper,
            String upchargeType, Decimal value) {
        return new Manufacturer_Upcharge__c(
            Manufacturer__c = manufacturerId,
            Quantity_Lower_Bound__c = lower,
            Quantity_Upper_Bound__c = upper,
            Upcharge_Type__c = upchargeType,
            Value__c = value
        );
    }

    private static QuoteCostService.TierCost tierFor(QuoteCostService.CostResult result, Integer quantity) {
        for (QuoteCostService.TierCost tier : result.tiers) {
            if (tier.quantity == quantity) {
                return tier;
            }
        }
        return null;
    }

    @IsTest
    static void calculatesLdpPerTierWithMultiplierUpcharges() {
        Fixture f = buildFixture();

        Test.startTest();
        QuoteCostService.CostResult result = QuoteCostService.calculate(
            f.baseStyle.Id, f.mainDecoration.Id, null, f.manufacturer.Id, TIERS);
        Test.stopTest();

        System.assertEquals(true, result.available, result.message);
        System.assertEquals(6.9737, result.baseFob, 'Blank 6.2737 + flat embroidery 0.70');
        System.assertEquals(0.045, result.percentCharges);
        System.assertEquals(0.10, result.fixedCharges);
        System.assertEquals(6, result.tiers.size());

        // 576 and above: no upcharge. 6.9737 * 1.045 + 0.10 = 7.3875
        System.assertEquals(null, tierFor(result, 576).upchargeType);
        System.assertEquals(7.3875, tierFor(result, 576).ldp);
        System.assertEquals(7.3875, tierFor(result, 1008).ldp);
        // 432: 6.9737 * 1.05 = 7.3224 -> 7.7519
        System.assertEquals(7.3224, tierFor(result, 432).fob);
        System.assertEquals(7.7519, tierFor(result, 432).ldp);
        // 288: 7.6711 -> 8.1163
        System.assertEquals(8.1163, tierFor(result, 288).ldp);
        // 144: 8.3684 -> 8.8450
        System.assertEquals(8.8450, tierFor(result, 144).ldp);
        // 72: 10.1119 -> 10.6669
        System.assertEquals(1.45, tierFor(result, 72).upchargeValue);
        System.assertEquals(10.6669, tierFor(result, 72).ldp);
    }

    @IsTest
    static void additionalDecorationsUseAdditionalLocationCostThenMainCost() {
        Fixture f = buildFixture();

        QuoteCostService.CostResult result = QuoteCostService.calculate(
            f.baseStyle.Id, f.mainDecoration.Id,
            new List<String>{ f.mainDecoration.Id, f.secondLocation.Id, f.uncosted.Id },
            f.manufacturer.Id, new List<Integer>{ 576 });

        System.assertEquals(true, result.available, result.message);
        // 6.2737 + 0.70 main + 0.49 second-location embroidery + 0.82 patch + 0 uncosted
        System.assertEquals(8.2837, result.baseFob);
        System.assertEquals(5, result.lines.size());
        System.assertEquals(2, result.warnings.size(), 'Fallback and uncosted decorations are flagged');
        System.assert(result.warnings[0].contains('Sublimation Patch'), 'Main-location cost fallback is flagged');
        System.assert(result.warnings[1].contains('UPC Sticker'), 'Uncosted decoration is flagged');
        // 8.2837 * 1.045 + 0.10 = 8.7565
        System.assertEquals(8.7565, result.tiers[0].ldp);
    }

    @IsTest
    static void additionalOnlyDecorationCostsWithoutWarningAndCannotBeMain() {
        Fixture f = buildFixture();

        QuoteCostService.CostResult asAdditional = QuoteCostService.calculate(
            f.baseStyle.Id, f.mainDecoration.Id, new List<String>{ f.additionalOnly.Id },
            f.manufacturer.Id, new List<Integer>{ 576 });
        System.assertEquals(true, asAdditional.available, asAdditional.message);
        System.assertEquals(7.2237, asAdditional.baseFob, '6.2737 + 0.70 + 0.25');
        System.assertEquals(0, asAdditional.warnings.size());

        QuoteCostService.CostResult asMain = QuoteCostService.calculate(
            f.baseStyle.Id, f.additionalOnly.Id, null, f.manufacturer.Id, new List<Integer>{ 576 });
        System.assertEquals(false, asMain.available, 'No main-location cost on file');
        System.assert(asMain.message.contains('Visor Rope'));
    }

    @IsTest
    static void dollarUpchargeAddsToFob() {
        Fixture f = buildFixture();
        delete [SELECT Id FROM Manufacturer_Upcharge__c WHERE Manufacturer__c = :f.manufacturer.Id];
        insert upcharge(f.manufacturer.Id, 144, 287, 'Dollar', 0.40);

        QuoteCostService.CostResult result = QuoteCostService.calculate(
            f.baseStyle.Id, f.mainDecoration.Id, null, f.manufacturer.Id, new List<Integer>{ 144 });

        System.assertEquals('Dollar', result.tiers[0].upchargeType);
        System.assertEquals(7.3737, result.tiers[0].fob);
        // 7.3737 * 1.045 + 0.10 = 7.8055
        System.assertEquals(7.8055, result.tiers[0].ldp);
    }

    @IsTest
    static void openEndedAndOverlappingRangesPreferHighestLowerBound() {
        Fixture f = buildFixture();
        insert upcharge(f.manufacturer.Id, 1, null, 'Multiplier', 2);

        QuoteCostService.CostResult result = QuoteCostService.calculate(
            f.baseStyle.Id, f.mainDecoration.Id, null, f.manufacturer.Id, new List<Integer>{ 36, 72, 576 });

        System.assertEquals(2, tierFor(result, 36).upchargeValue, 'Only the open-ended row covers 36');
        System.assertEquals(1.45, tierFor(result, 72).upchargeValue, 'The narrower row wins at 72');
        System.assertEquals(2, tierFor(result, 576).upchargeValue, 'The open-ended row covers 576');
    }

    @IsTest
    static void missingCostDataReturnsUnavailableWithMessage() {
        Fixture f = buildFixture();

        QuoteCostService.CostResult noInputs = QuoteCostService.calculate(null, null, null, null, TIERS);
        System.assertEquals(false, noInputs.available);

        QuoteCostService.CostResult noManufacturer = QuoteCostService.calculate(
            f.baseStyle.Id, f.mainDecoration.Id, null, null, TIERS);
        System.assertEquals(false, noManufacturer.available);
        System.assert(noManufacturer.message.contains('manufacturer'));

        QuoteCostService.CostResult noTiers = QuoteCostService.calculate(
            f.baseStyle.Id, f.mainDecoration.Id, null, f.manufacturer.Id, new List<Integer>{ 0, -5, null });
        System.assertEquals(false, noTiers.available);

        QuoteCostService.CostResult badId = QuoteCostService.calculate(
            f.baseStyle.Id, f.mainDecoration.Id, new List<String>{ 'not-an-id' }, f.manufacturer.Id, TIERS);
        System.assertEquals(false, badId.available);

        // Main decoration without a cost.
        QuoteCostService.CostResult noDecorationCost = QuoteCostService.calculate(
            f.baseStyle.Id, f.uncosted.Id, null, f.manufacturer.Id, TIERS);
        System.assertEquals(false, noDecorationCost.available);
        System.assert(noDecorationCost.message.contains('UPC Sticker'));

        // Base style without a blank FOB.
        QuoteCostService.CostResult noBlankFob = QuoteCostService.calculate(
            f.uncosted.Id, f.mainDecoration.Id, null, f.manufacturer.Id, TIERS);
        System.assertEquals(false, noBlankFob.available);
        System.assert(noBlankFob.message.contains('Blank FOB'));

        // Manufacturer with no charges configured.
        mfg__c bare = new mfg__c(Name = 'Bare Manufacturer');
        insert bare;
        QuoteCostService.CostResult noCharges = QuoteCostService.calculate(
            f.baseStyle.Id, f.mainDecoration.Id, null, bare.Id, TIERS);
        System.assertEquals(false, noCharges.available);
        System.assert(noCharges.message.contains('no LDP charges'));
    }

    @IsTest
    static void duplicateQuantitiesAreCollapsedAndSorted() {
        Fixture f = buildFixture();

        QuoteCostService.CostResult result = QuoteCostService.calculate(
            f.baseStyle.Id, f.mainDecoration.Id, null, f.manufacturer.Id,
            new List<Integer>{ 576, 72, 576, 144 });

        System.assertEquals(3, result.tiers.size());
        System.assertEquals(72, result.tiers[0].quantity);
        System.assertEquals(576, result.tiers[2].quantity);
    }

    @IsTest
    static void pureHelpersHandleNullsAndUnknownTypes() {
        System.assertEquals(null, QuoteCostService.applyUpcharge(null, 'Multiplier', 1.2));
        System.assertEquals(5, QuoteCostService.applyUpcharge(5, null, null));
        System.assertEquals(5, QuoteCostService.applyUpcharge(5, 'Unknown', 3));
        System.assertEquals(5, QuoteCostService.applyUpcharge(5, 'Multiplier', 0), 'Zero multiplier is ignored');
        System.assertEquals(null, QuoteCostService.computeLdp(null, new QuoteCostService.Charges()));
        System.assertEquals(null, QuoteCostService.computeLdp(5, null));

        System.assertEquals(true, QuoteCostService.isNorthAmericanCustom('QuickTurnNAC'));
        System.assertEquals(true, QuoteCostService.isNorthAmericanCustom(' quickturnnac '));
        System.assertEquals(false, QuoteCostService.isNorthAmericanCustom('QuickTurn'));
        System.assertEquals(false, QuoteCostService.isNorthAmericanCustom(null));
        System.assertEquals(true, QuoteCostService.isQuickProgram('QuickTurn'));
        System.assertEquals(false, QuoteCostService.isQuickProgram(null));
    }

    @IsTest
    static void controllerEndpointConvertsQuantitiesAndReturnsCosts() {
        Fixture f = buildFixture();

        QuoteCostService.CostResult result = QuoteProductController.getQuickTurnCosts(
            f.baseStyle.Id, f.mainDecoration.Id, new List<String>(), f.manufacturer.Id,
            new List<Decimal>{ 144, 576.0, null });

        System.assertEquals(true, result.available, result.message);
        System.assertEquals(2, result.tiers.size());
        System.assertEquals(f.manufacturer.Id, result.manufacturerId);
    }
}
