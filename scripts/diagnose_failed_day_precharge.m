%% diagnose_failed_day_precharge.m
% Diagnose whether forecast-based precharging can correct
% the failed day identified in the seven-day simulation.

clear;
clc;
close all;

%% 1. Project paths

scriptDir  = fileparts(mfilename('fullpath'));
projectDir = fileparts(scriptDir);

dataDir    = fullfile(projectDir, 'data');
modelDir   = fullfile(projectDir, 'model');
resultsDir = fullfile(projectDir, 'results');

modelName = 'PV_BESS_EMS';
modelFile = fullfile(modelDir, [modelName '.slx']);

sevenDayFile = fullfile( ...
    resultsDir, ...
    'seven_day_sequential_results.mat');

assert(isfile(sevenDayFile), ...
    'seven_day_sequential_results.mat was not found.');

addpath(modelDir);
load_system(modelFile);

set_param(modelName, 'StopTime', '86400');
set_param(modelName, 'FastRestart', 'off');

%% 2. Load seven-day results

load(sevenDayFile, 'sevenDayResults');

failedIndices = find( ...
    ~sevenDayResults.MeetsGridLimit);

assert(~isempty(failedIndices), ...
    'No failed day was found.');

assert(numel(failedIndices) == 1, ...
    'More than one failed day was found. Check the table first.');

failedIndex = failedIndices(1);

failedDay = ...
    sevenDayResults.DayNumber(failedIndex);

failedScenario = ...
    sevenDayResults.Scenario(failedIndex);

failedInitialSOC = ...
    sevenDayResults.InitialSOC_pct(failedIndex) / 100;

failedPVScale = ...
    sevenDayResults.PVScale(failedIndex);

failedLoadScale = ...
    sevenDayResults.LoadScale(failedIndex);

originalPrechargeFlag = ...
    sevenDayResults.PrechargeEnable(failedIndex);

fprintf('\n--- Failed Day Identified ---\n');

fprintf('Day number: %d\n', failedDay);
fprintf('Scenario: %s\n', char(failedScenario));
fprintf('Initial SOC: %.3f %%\n', ...
    100 * failedInitialSOC);

fprintf('Original precharge flag: %.0f\n', ...
    originalPrechargeFlag);

assert(originalPrechargeFlag < 0.5, ...
    ['The failed day already used precharging. ' ...
     'A different diagnostic is required.']);

%% 3. Load base profiles

loadData = load(fullfile(dataDir, 'load_profile.mat'));
pvData   = load(fullfile(dataDir, 'pv_profile.mat'));

baseTime = loadData.load_profile.Time(:);
baseLoad = loadData.load_profile.Data(:);
basePV   = pvData.pv_profile.Data(:);

currentLoad = baseLoad * failedLoadScale;
currentPV   = basePV * failedPVScale;

load_profile_case = timeseries( ...
    currentLoad, baseTime);

pv_profile_case = timeseries( ...
    currentPV, baseTime);

%% 4. Fixed BESS parameters

E_batt_kWh = 340;
P_batt_max_kW = 70;
P_grid_limit_kW = 100;

%% 5. Define the controlled comparison

CaseName = [
    "Original schedule"
    "Forced precharge"
];

PrechargeEnable = [
    originalPrechargeFlag
    1
];

numberOfCases = numel(CaseName);

PeakGrid_kW = zeros(numberOfCases, 1);
GridExceedance_kWh = zeros(numberOfCases, 1);

MinimumSOC_pct = zeros(numberOfCases, 1);
MaximumSOC_pct = zeros(numberOfCases, 1);
FinalSOC_pct = zeros(numberOfCases, 1);

MaximumBatteryPower_kW = zeros(numberOfCases, 1);
MaximumPowerBalanceError_kW = zeros(numberOfCases, 1);

MeetsGridLimit = false(numberOfCases, 1);
SOCWithinLimits = false(numberOfCases, 1);
BatteryPowerWithinRating = false(numberOfCases, 1);

timeResult = cell(numberOfCases, 1);
gridResult = cell(numberOfCases, 1);
socResult = cell(numberOfCases, 1);

%% 6. Run original and forced-precharge cases

for caseIndex = 1:numberOfCases

    fprintf('\nRunning case %d: %s\n', ...
        caseIndex, CaseName(caseIndex));

    assignin('base', ...
        'load_profile', load_profile_case);

    assignin('base', ...
        'pv_profile', pv_profile_case);

    assignin('base', ...
        'E_batt', E_batt_kWh);

    assignin('base', ...
        'E_batt_kWh', E_batt_kWh);

    assignin('base', ...
        'P_batt_max', P_batt_max_kW);

    assignin('base', ...
        'P_batt_max_kW', P_batt_max_kW);

    assignin('base', ...
        'P_grid_limit', P_grid_limit_kW);

    assignin('base', ...
        'P_grid_limit_kW', P_grid_limit_kW);

    % Both cases use exactly the same initial SOC
    assignin('base', ...
        'SOC_initial', failedInitialSOC);

    assignin('base', ...
        'precharge_enable', ...
        PrechargeEnable(caseIndex));

    Simulink.sdi.clear;

    simOut = sim(modelName, ...
        'StopTime', '86400', ...
        'ReturnWorkspaceOutputs', 'on');

    P_grid_ts = simOut.get('P_grid_ems_sim');
    P_batt_ts = simOut.get('P_batt_sim');
    SOC_ts    = simOut.get('SOC_sim');

    dayTime = P_grid_ts.Time(:);
    P_grid  = P_grid_ts.Data(:);
    P_batt  = P_batt_ts.Data(:);
    SOC     = SOC_ts.Data(:);

    %% KPIs

    PeakGrid_kW(caseIndex) = max(P_grid);

    excessPower = max( ...
        P_grid - P_grid_limit_kW, 0);

    GridExceedance_kWh(caseIndex) = ...
        trapz(dayTime, excessPower) / 3600;

    MinimumSOC_pct(caseIndex) = ...
        100 * min(SOC);

    MaximumSOC_pct(caseIndex) = ...
        100 * max(SOC);

    FinalSOC_pct(caseIndex) = ...
        100 * SOC(end);

    MaximumBatteryPower_kW(caseIndex) = ...
        max(abs(P_batt));

    MeetsGridLimit(caseIndex) = ...
        PeakGrid_kW(caseIndex) <= ...
        P_grid_limit_kW + 0.01 && ...
        GridExceedance_kWh(caseIndex) <= 0.01;

    SOCWithinLimits(caseIndex) = ...
        min(SOC) >= 0.20 - 1e-6 && ...
        max(SOC) <= 0.90 + 1e-6;

    BatteryPowerWithinRating(caseIndex) = ...
        max(abs(P_batt)) <= ...
        P_batt_max_kW + 1e-6;

    %% Power-balance check

    P_net = currentLoad - currentPV;

    commonLength = min([ ...
        numel(P_net), ...
        numel(P_grid), ...
        numel(P_batt)]);

    balanceError = ...
        P_grid(1:commonLength) - ...
        (P_net(1:commonLength) - ...
         P_batt(1:commonLength));

    MaximumPowerBalanceError_kW(caseIndex) = ...
        max(abs(balanceError));

    %% Save curves

    timeResult{caseIndex} = dayTime;
    gridResult{caseIndex} = P_grid;
    socResult{caseIndex} = 100 * SOC;

end

%% 7. Comparison table

failedDayDiagnostic = table( ...
    CaseName, ...
    PrechargeEnable, ...
    PeakGrid_kW, ...
    GridExceedance_kWh, ...
    MinimumSOC_pct, ...
    MaximumSOC_pct, ...
    FinalSOC_pct, ...
    MaximumBatteryPower_kW, ...
    MaximumPowerBalanceError_kW, ...
    MeetsGridLimit, ...
    SOCWithinLimits, ...
    BatteryPowerWithinRating);

fprintf('\n--- Failed Day Precharge Diagnostic ---\n');

disp(failedDayDiagnostic);

%% 8. Quantify improvement

peakImprovement_kW = ...
    PeakGrid_kW(1) - PeakGrid_kW(2);

exceedanceImprovement_kWh = ...
    GridExceedance_kWh(1) - ...
    GridExceedance_kWh(2);

fprintf('\n--- Precharge Improvement ---\n');

fprintf('Peak-grid reduction: %.3f kW\n', ...
    peakImprovement_kW);

fprintf('Grid-exceedance energy reduction: %.3f kWh\n', ...
    exceedanceImprovement_kWh);

fprintf('Original case compliant: %d\n', ...
    MeetsGridLimit(1));

fprintf('Forced-precharge case compliant: %d\n', ...
    MeetsGridLimit(2));

%% 9. Save results

csvFile = fullfile( ...
    resultsDir, ...
    'failed_day_precharge_diagnostic.csv');

matFile = fullfile( ...
    resultsDir, ...
    'failed_day_precharge_diagnostic.mat');

writetable(failedDayDiagnostic, csvFile);

save(matFile, ...
    'failedDayDiagnostic', ...
    'failedDay', ...
    'failedScenario', ...
    'failedInitialSOC', ...
    'timeResult', ...
    'gridResult', ...
    'socResult');

%% 10. Plot comparison

figure( ...
    'Color', 'w', ...
    'Name', 'Failed Day Precharge Diagnostic');

tiledlayout(2, 1, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');

nexttile;

plot( ...
    timeResult{1} / 3600, ...
    gridResult{1}, ...
    '--', ...
    'LineWidth', 1.8);

hold on;

plot( ...
    timeResult{2} / 3600, ...
    gridResult{2}, ...
    '-', ...
    'LineWidth', 1.8);

yline( ...
    P_grid_limit_kW, ...
    'r--', ...
    '100 kW grid limit', ...
    'LineWidth', 1.5);

grid on;
box on;

xlim([0 24]);

ylabel('Grid power (kW)');
title('Grid Power on the Failed Day');

legend(CaseName, ...
    'Location', 'best');

nexttile;

plot( ...
    timeResult{1} / 3600, ...
    socResult{1}, ...
    '--', ...
    'LineWidth', 1.8);

hold on;

plot( ...
    timeResult{2} / 3600, ...
    socResult{2}, ...
    '-', ...
    'LineWidth', 1.8);

yline(20, ...
    'r--', ...
    '20% SOC limit');

yline(25, ...
    'k--', ...
    '25% design target');

yline(90, ...
    'r--', ...
    '90% SOC limit');

grid on;
box on;

xlim([0 24]);

xlabel('Time of day (h)');
ylabel('SOC (%)');
title('SOC with and without Precharging');

legend(CaseName, ...
    'Location', 'best');

sgtitle(sprintf( ...
    'Day %d Diagnostic: %s', ...
    failedDay, char(failedScenario)));

exportgraphics(gcf, ...
    fullfile(resultsDir, ...
    'failed_day_precharge_diagnostic.png'), ...
    'Resolution', 300);

fprintf('\nResults saved to:\n%s\n', resultsDir);