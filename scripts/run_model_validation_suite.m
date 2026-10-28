%% run_model_validation_suite.m
% Automated engineering validation suite for the PV-BESS EMS model.
%
% A test passes when the simulated result matches the expected
% physical behaviour and all safety constraints remain satisfied.

clear;
clc;
close all;

%% 1. Project paths

scriptDir  = fileparts(mfilename('fullpath'));
projectDir = fileparts(scriptDir);

dataDir    = fullfile(projectDir, 'data');
modelDir   = fullfile(projectDir, 'model');
resultsDir = fullfile(projectDir, 'results');

if ~exist(resultsDir, 'dir')
    mkdir(resultsDir);
end

modelName = 'PV_BESS_EMS';
modelFile = fullfile(modelDir, [modelName '.slx']);

addpath(modelDir);
load_system(modelFile);

set_param(modelName, 'StopTime', '86400');
set_param(modelName, 'FastRestart', 'off');

%% 2. Load validated profiles

loadData = load(fullfile(dataDir, 'load_profile.mat'));
pvData   = load(fullfile(dataDir, 'pv_profile.mat'));

baseTime = loadData.load_profile.Time(:);
baseLoad = loadData.load_profile.Data(:);
basePV   = pvData.pv_profile.Data(:);

assert(numel(baseLoad) == numel(basePV), ...
    'Load and PV profiles must have the same length.');

%% 3. Global validation limits

P_grid_limit_kW = 100;

SOC_min = 0.20;
SOC_max = 0.90;

powerBalanceTolerance_kW = 1e-6;
constraintTolerance = 1e-6;

%% 4. Define validation test matrix

TestName = [
    "Nominal operation"
    "Complete PV outage"
    "Load surge - combined constraints"
    "Undersized battery energy"
    "Battery unavailable"
];

PlotLabel = [
    "Nominal"
    "PV outage"
    "Load surge"
    "Small battery"
    "BESS unavailable"
];

% Load-profile multiplier
LoadScale = [
    1.00
    1.00
    1.30
    1.15
    1.00
];

% PV-profile multiplier
PVScale = [
    1.00
    0.00
    1.00
    0.55
    1.00
];

BatteryCapacity_kWh = [
    340
    340
    340
    100
    340
];

BatteryPowerRating_kW = [
    70
    70
    70
    70
    0
];

InitialSOC_command = [
    0.50
    0.90
    0.90
    0.90
    0.50
];

PrechargeEnable = [
    0
    0
    1
    1
    0
];

% Expected grid-compliance behaviour
ExpectedGridCompliance = [
    true
    true
    false
    false
    false
];

ExpectedBehaviour = [
    "Normal system should meet the grid limit"
    "Adequate stored energy should compensate for zero PV"
    "Battery reaches the 70 kW power limit and later exhausts usable SOC under a sustained load surge"
    "Battery reaches minimum SOC because energy is insufficient"
    "Grid follows net load because battery power rating is zero"
];

numberOfTests = numel(TestName);

%% 5. Preallocate measured results

PeakGrid_kW = zeros(numberOfTests, 1);
GridExceedance_kWh = zeros(numberOfTests, 1);

MinimumSOC_pct = zeros(numberOfTests, 1);
MaximumSOC_pct = zeros(numberOfTests, 1);
FinalSOC_pct = zeros(numberOfTests, 1);

MaximumBatteryPower_kW = zeros(numberOfTests, 1);
MaximumPowerBalanceError_kW = zeros(numberOfTests, 1);

ActualGridCompliance = false(numberOfTests, 1);

SOCConstraintPassed = false(numberOfTests, 1);
PowerConstraintPassed = false(numberOfTests, 1);
PowerBalancePassed = false(numberOfTests, 1);

ComplianceExpectationPassed = false(numberOfTests, 1);
OverallTestPassed = false(numberOfTests, 1);

%% 6. Run validation cases

for testIndex = 1:numberOfTests

    fprintf('\n========================================\n');
    fprintf('Running validation test %d of %d\n', ...
        testIndex, numberOfTests);
    fprintf('Test: %s\n', TestName(testIndex));
    fprintf('========================================\n');

    %% 6.1 Create test profiles

    currentLoad = ...
        baseLoad * LoadScale(testIndex);

    currentPV = ...
        basePV * PVScale(testIndex);

    load_profile_case = timeseries( ...
        currentLoad, baseTime);

    pv_profile_case = timeseries( ...
        currentPV, baseTime);

    %% 6.2 Assign simulation parameters

    currentCapacity = ...
        BatteryCapacity_kWh(testIndex);

    currentPowerRating = ...
        BatteryPowerRating_kW(testIndex);

    assignin('base', ...
        'load_profile', load_profile_case);

    assignin('base', ...
        'pv_profile', pv_profile_case);

    assignin('base', ...
        'E_batt', currentCapacity);

    assignin('base', ...
        'E_batt_kWh', currentCapacity);

    assignin('base', ...
        'P_batt_max', currentPowerRating);

    assignin('base', ...
        'P_batt_max_kW', currentPowerRating);

    assignin('base', ...
        'P_grid_limit', P_grid_limit_kW);

    assignin('base', ...
        'P_grid_limit_kW', P_grid_limit_kW);

    assignin('base', ...
        'SOC_initial', ...
        InitialSOC_command(testIndex));

    assignin('base', ...
        'precharge_enable', ...
        PrechargeEnable(testIndex));

    Simulink.sdi.clear;

    %% 6.3 Run model

    simOut = sim(modelName, ...
        'StopTime', '86400', ...
        'ReturnWorkspaceOutputs', 'on');

    %% 6.4 Extract outputs

    P_grid_ts = ...
        simOut.get('P_grid_ems_sim');

    P_batt_ts = ...
        simOut.get('P_batt_sim');

    SOC_ts = ...
        simOut.get('SOC_sim');

    testTime = P_grid_ts.Time(:);
    P_grid = P_grid_ts.Data(:);
    P_batt = P_batt_ts.Data(:);
    SOC = SOC_ts.Data(:);

    %% 6.5 Calculate KPIs

    PeakGrid_kW(testIndex) = ...
        max(P_grid);

    excessPower = max( ...
        P_grid - P_grid_limit_kW, 0);

    GridExceedance_kWh(testIndex) = ...
        trapz(testTime, excessPower) / 3600;

    MinimumSOC_pct(testIndex) = ...
        100 * min(SOC);

    MaximumSOC_pct(testIndex) = ...
        100 * max(SOC);

    FinalSOC_pct(testIndex) = ...
        100 * SOC(end);

    MaximumBatteryPower_kW(testIndex) = ...
        max(abs(P_batt));

    %% 6.6 Verify grid performance

    ActualGridCompliance(testIndex) = ...
        PeakGrid_kW(testIndex) <= ...
        P_grid_limit_kW + 0.01 && ...
        GridExceedance_kWh(testIndex) <= 0.01;

    ComplianceExpectationPassed(testIndex) = ...
        ActualGridCompliance(testIndex) == ...
        ExpectedGridCompliance(testIndex);

    %% 6.7 Verify SOC and power constraints

    SOCConstraintPassed(testIndex) = ...
        min(SOC) >= ...
        SOC_min - constraintTolerance && ...
        max(SOC) <= ...
        SOC_max + constraintTolerance;

    PowerConstraintPassed(testIndex) = ...
        max(abs(P_batt)) <= ...
        currentPowerRating + ...
        constraintTolerance;

    %% 6.8 Verify power balance

    P_net = currentLoad - currentPV;

    commonLength = min([ ...
        numel(P_net), ...
        numel(P_grid), ...
        numel(P_batt)]);

    balanceError = ...
        P_grid(1:commonLength) - ...
        (P_net(1:commonLength) - ...
         P_batt(1:commonLength));

    MaximumPowerBalanceError_kW(testIndex) = ...
        max(abs(balanceError));

    PowerBalancePassed(testIndex) = ...
        MaximumPowerBalanceError_kW(testIndex) <= ...
        powerBalanceTolerance_kW;

    %% 6.9 Overall test result

    OverallTestPassed(testIndex) = ...
        ComplianceExpectationPassed(testIndex) && ...
        SOCConstraintPassed(testIndex) && ...
        PowerConstraintPassed(testIndex) && ...
        PowerBalancePassed(testIndex);

end

%% 7. Create validation table

validationResults = table( ...
    TestName, ...
    ExpectedBehaviour, ...
    LoadScale, ...
    PVScale, ...
    BatteryCapacity_kWh, ...
    BatteryPowerRating_kW, ...
    InitialSOC_command, ...
    PrechargeEnable, ...
    ExpectedGridCompliance, ...
    ActualGridCompliance, ...
    PeakGrid_kW, ...
    GridExceedance_kWh, ...
    MinimumSOC_pct, ...
    MaximumSOC_pct, ...
    FinalSOC_pct, ...
    MaximumBatteryPower_kW, ...
    MaximumPowerBalanceError_kW, ...
    ComplianceExpectationPassed, ...
    SOCConstraintPassed, ...
    PowerConstraintPassed, ...
    PowerBalancePassed, ...
    OverallTestPassed);

fprintf('\n--- PV-BESS EMS Validation Matrix ---\n');

disp(validationResults(:, { ...
    'TestName', ...
    'ExpectedGridCompliance', ...
    'ActualGridCompliance', ...
    'PeakGrid_kW', ...
    'GridExceedance_kWh', ...
    'MinimumSOC_pct', ...
    'MaximumBatteryPower_kW', ...
    'MaximumPowerBalanceError_kW', ...
    'OverallTestPassed'}));

%% 8. Print validation verdict

fprintf('\n--- Validation Verdict ---\n');

fprintf('Tests passed: %d of %d\n', ...
    sum(OverallTestPassed), numberOfTests);

fprintf('SOC-constraint checks passed: %d of %d\n', ...
    sum(SOCConstraintPassed), numberOfTests);

fprintf('Power-rating checks passed: %d of %d\n', ...
    sum(PowerConstraintPassed), numberOfTests);

fprintf('Power-balance checks passed: %d of %d\n', ...
    sum(PowerBalancePassed), numberOfTests);

if all(OverallTestPassed)

    fprintf('OVERALL RESULT: PASS\n');

else

    fprintf('OVERALL RESULT: REVIEW REQUIRED\n');

    fprintf('\nFailed validation rows:\n');

    disp(validationResults( ...
        ~validationResults.OverallTestPassed, :));

end

%% 9. Save results

csvFile = fullfile( ...
    resultsDir, ...
    'model_validation_results.csv');

matFile = fullfile( ...
    resultsDir, ...
    'model_validation_results.mat');

writetable(validationResults, csvFile);

save(matFile, ...
    'validationResults', ...
    'P_grid_limit_kW', ...
    'SOC_min', ...
    'SOC_max');

%% 10. Plot validation results

x = 1:numberOfTests;

figure( ...
    'Color', 'w', ...
    'Name', 'PV-BESS EMS Validation Matrix');

tiledlayout(1, 3, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');

% Grid-performance result
nexttile;

bar(x, PeakGrid_kW);

hold on;

yline(100, ...
    'r--', ...
    '100 kW limit', ...
    'LineWidth', 1.5);

grid on;
box on;

xticks(x);
xticklabels(PlotLabel);
xtickangle(20);

ylabel('Peak grid power (kW)');
title('Grid-limit Response');

% Battery-power constraint
nexttile;

bar(x, [ ...
    MaximumBatteryPower_kW, ...
    BatteryPowerRating_kW]);

grid on;
box on;

xticks(x);
xticklabels(PlotLabel);
xtickangle(20);

ylabel('Battery power (kW)');
title('Battery Power Constraint');

legend( ...
    'Maximum simulated power', ...
    'Power rating', ...
    'Location', 'best');

% SOC constraint
nexttile;

bar(x, [ ...
    MinimumSOC_pct, ...
    MaximumSOC_pct]);

hold on;

yline(20, ...
    'r--', ...
    '20% lower limit');

yline(90, ...
    'r--', ...
    '90% upper limit');

grid on;
box on;

xticks(x);
xticklabels(PlotLabel);
xtickangle(20);

ylabel('SOC (%)');
title('SOC Constraint');

legend( ...
    'Minimum SOC', ...
    'Maximum SOC', ...
    'Location', 'best');

sgtitle( ...
    'PV-BESS EMS Engineering Validation Suite');

exportgraphics(gcf, ...
    fullfile(resultsDir, ...
    'model_validation_results.png'), ...
    'Resolution', 300);

fprintf('\nResults saved to:\n%s\n', resultsDir);