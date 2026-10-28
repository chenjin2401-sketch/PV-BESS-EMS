%% run_7day_sequential_simulation.m
% Seven-day sequential simulation with SOC state handover.
%
% Day n final SOC becomes Day n+1 initial SOC.

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

%% 2. Load validated one-day profiles

loadData = load(fullfile(dataDir, 'load_profile.mat'));
pvData   = load(fullfile(dataDir, 'pv_profile.mat'));

baseTime = loadData.load_profile.Time(:);
baseLoad = loadData.load_profile.Data(:);

pvTime = pvData.pv_profile.Time(:);
basePV = pvData.pv_profile.Data(:);

assert(numel(baseLoad) == numel(basePV), ...
    'Load and PV profiles must have the same number of samples.');

assert(max(abs(baseTime - pvTime)) < 1e-6, ...
    'Load and PV time vectors must be identical.');

assert(abs(baseTime(1)) < 1e-6, ...
    'The daily profile must start at 0 seconds.');

assert(abs(baseTime(end) - 86400) < 1e-6, ...
    'The daily profile must end at 86400 seconds.');

%% 3. Selected BESS design

E_batt_kWh = 340;
P_batt_max_kW = 70;
P_grid_limit_kW = 100;

SOC_min = 0.20;
SOC_max = 0.90;

initialProjectSOC = 0.50;

%% 4. Seven-day scenario schedule

DayNumber = (1:7)';

Scenario = [
    "Sunny / Normal Load"
    "Sunny / Normal Load"
    "Cloudy / Normal Load"
    "Cloudy / High Load"
    "Cloudy / High Load"
    "Sunny / High Load"
    "Sunny / Normal Load"
];

PVScale = [
    1.00
    1.00
    0.55
    0.55
    0.55
    1.00
    1.00
];

LoadScale = [
    1.00
    1.00
    1.00
    1.15
    1.15
    1.15
    1.00
];

% Precharge is enabled when the next operating day is expected
% to have cloudy weather or high demand.
PrechargeEnable = [
    0
    0
    1
    1
    1
    1
    0
];

numberOfDays = numel(DayNumber);

%% 5. Preallocate daily KPI arrays

InitialSOC_pct = zeros(numberOfDays, 1);
FinalSOC_pct   = zeros(numberOfDays, 1);
MinimumSOC_pct = zeros(numberOfDays, 1);
MaximumSOC_pct = zeros(numberOfDays, 1);

PeakGrid_kW        = zeros(numberOfDays, 1);
GridExceedance_kWh = zeros(numberOfDays, 1);
GridImport_kWh     = zeros(numberOfDays, 1);
BatteryThroughput_kWh = zeros(numberOfDays, 1);

HandoverError_pct = zeros(numberOfDays, 1);
MaximumPowerBalanceError_kW = zeros(numberOfDays, 1);

MeetsGridLimit = false(numberOfDays, 1);
SOCWithinLimits = false(numberOfDays, 1);
BatteryPowerWithinRating = false(numberOfDays, 1);

%% 6. Arrays for continuous seven-day plots

continuousTime_sec = [];
continuousSOC_pct = [];
continuousGridPower_kW = [];
continuousBatteryPower_kW = [];

%% 7. Run the seven daily simulations

for dayIndex = 1:numberOfDays

    fprintf('\nRunning Day %d of %d: %s\n', ...
        dayIndex, numberOfDays, Scenario(dayIndex));

    %% 7.1 Set initial SOC from previous day

    if dayIndex == 1

        currentInitialSOC = initialProjectSOC;

    else

        currentInitialSOC = FinalSOC_pct(dayIndex - 1) / 100;

    end

    InitialSOC_pct(dayIndex) = 100 * currentInitialSOC;

    if dayIndex == 1

        HandoverError_pct(dayIndex) = 0;

    else

        HandoverError_pct(dayIndex) = abs( ...
            InitialSOC_pct(dayIndex) - ...
            FinalSOC_pct(dayIndex - 1));

    end

    %% 7.2 Generate the current day's profiles

    currentLoad = baseLoad * LoadScale(dayIndex);
    currentPV   = basePV * PVScale(dayIndex);

    load_profile_case = timeseries( ...
        currentLoad, baseTime);

    pv_profile_case = timeseries( ...
        currentPV, baseTime);

    %% 7.3 Assign all inputs to base workspace

    assignin('base', 'load_profile', load_profile_case);
    assignin('base', 'pv_profile', pv_profile_case);

    assignin('base', 'E_batt', E_batt_kWh);
    assignin('base', 'E_batt_kWh', E_batt_kWh);

    assignin('base', 'P_batt_max', P_batt_max_kW);
    assignin('base', 'P_batt_max_kW', P_batt_max_kW);

    assignin('base', 'P_grid_limit', P_grid_limit_kW);
    assignin('base', 'P_grid_limit_kW', P_grid_limit_kW);

    assignin('base', 'SOC_initial', currentInitialSOC);

    assignin('base', 'precharge_enable', ...
        PrechargeEnable(dayIndex));

    %% 7.4 Clear old logged runs

    Simulink.sdi.clear;

    %% 7.5 Run one day

    simOut = sim(modelName, ...
        'StopTime', '86400', ...
        'ReturnWorkspaceOutputs', 'on');

    %% 7.6 Extract simulation outputs

    P_grid_ems_ts = simOut.get('P_grid_ems_sim');
    P_batt_ts     = simOut.get('P_batt_sim');
    SOC_ts        = simOut.get('SOC_sim');

    dayTime = P_grid_ems_ts.Time(:);
    P_grid  = P_grid_ems_ts.Data(:);
    P_batt  = P_batt_ts.Data(:);
    SOC     = SOC_ts.Data(:);

    assert(~isempty(P_grid), ...
        'P_grid_ems_sim is empty on Day %d.', dayIndex);

    assert(~isempty(P_batt), ...
        'P_batt_sim is empty on Day %d.', dayIndex);

    assert(~isempty(SOC), ...
        'SOC_sim is empty on Day %d.', dayIndex);

    %% 7.7 Daily KPIs

    FinalSOC_pct(dayIndex)   = 100 * SOC(end);
    MinimumSOC_pct(dayIndex) = 100 * min(SOC);
    MaximumSOC_pct(dayIndex) = 100 * max(SOC);

    PeakGrid_kW(dayIndex) = max(P_grid);

    gridExcessPower = max( ...
        P_grid - P_grid_limit_kW, 0);

    GridExceedance_kWh(dayIndex) = ...
        trapz(dayTime, gridExcessPower) / 3600;

    GridImport_kWh(dayIndex) = ...
        trapz(dayTime, max(P_grid, 0)) / 3600;

    BatteryThroughput_kWh(dayIndex) = ...
        trapz(dayTime, abs(P_batt)) / 3600;

    MeetsGridLimit(dayIndex) = ...
        PeakGrid_kW(dayIndex) <= ...
        P_grid_limit_kW + 0.01 && ...
        GridExceedance_kWh(dayIndex) <= 0.01;

    SOCWithinLimits(dayIndex) = ...
        min(SOC) >= SOC_min - 1e-6 && ...
        max(SOC) <= SOC_max + 1e-6;

    BatteryPowerWithinRating(dayIndex) = ...
        max(abs(P_batt)) <= ...
        P_batt_max_kW + 1e-6;

    %% 7.8 Power-balance verification

    P_net = currentLoad - currentPV;

    numberOfCommonSamples = min([ ...
        numel(P_net), ...
        numel(P_grid), ...
        numel(P_batt)]);

    balanceError = ...
        P_grid(1:numberOfCommonSamples) - ...
        (P_net(1:numberOfCommonSamples) - ...
        P_batt(1:numberOfCommonSamples));

    MaximumPowerBalanceError_kW(dayIndex) = ...
        max(abs(balanceError));

    %% 7.9 Append current day to continuous curves

    % Remove duplicate 24:00/00:00 points between adjacent days.
    if dayIndex < numberOfDays

        keepSample = dayTime < 86400;

    else

        keepSample = dayTime <= 86400;

    end

    globalTime = ...
        (dayIndex - 1) * 86400 + ...
        dayTime(keepSample);

    continuousTime_sec = [
        continuousTime_sec
        globalTime
    ];

    continuousSOC_pct = [
        continuousSOC_pct
        100 * SOC(keepSample)
    ];

    continuousGridPower_kW = [
        continuousGridPower_kW
        P_grid(keepSample)
    ];

    continuousBatteryPower_kW = [
        continuousBatteryPower_kW
        P_batt(keepSample)
    ];

    %% 7.10 Print daily handover result

    fprintf('Initial SOC: %.2f %%\n', ...
        InitialSOC_pct(dayIndex));

    fprintf('Final SOC: %.2f %%\n', ...
        FinalSOC_pct(dayIndex));

    fprintf('Minimum SOC: %.2f %%\n', ...
        MinimumSOC_pct(dayIndex));

    fprintf('Peak grid import: %.2f kW\n', ...
        PeakGrid_kW(dayIndex));

end

%% 8. Create daily result table

sevenDayResults = table( ...
    DayNumber, ...
    Scenario, ...
    PVScale, ...
    LoadScale, ...
    PrechargeEnable, ...
    InitialSOC_pct, ...
    FinalSOC_pct, ...
    MinimumSOC_pct, ...
    MaximumSOC_pct, ...
    PeakGrid_kW, ...
    GridExceedance_kWh, ...
    GridImport_kWh, ...
    BatteryThroughput_kWh, ...
    HandoverError_pct, ...
    MaximumPowerBalanceError_kW, ...
    MeetsGridLimit, ...
    SOCWithinLimits, ...
    BatteryPowerWithinRating);

fprintf('\n--- Seven-day Sequential Simulation Summary ---\n');

disp(sevenDayResults(:, { ...
    'DayNumber', ...
    'Scenario', ...
    'PrechargeEnable', ...
    'InitialSOC_pct', ...
    'FinalSOC_pct', ...
    'MinimumSOC_pct', ...
    'PeakGrid_kW', ...
    'GridExceedance_kWh', ...
    'HandoverError_pct', ...
    'MeetsGridLimit'}));

%% 9. Overall validation summary

fprintf('\n--- Seven-day Validation Checks ---\n');

fprintf('Maximum SOC handover error: %.6f percentage points\n', ...
    max(HandoverError_pct));

fprintf('Overall minimum SOC: %.3f %%\n', ...
    min(MinimumSOC_pct));

fprintf('Overall maximum SOC: %.3f %%\n', ...
    max(MaximumSOC_pct));

fprintf('Maximum grid import: %.3f kW\n', ...
    max(PeakGrid_kW));

fprintf('Maximum power-balance error: %.9f kW\n', ...
    max(MaximumPowerBalanceError_kW));

fprintf('Grid-compliant days: %d of %d\n', ...
    sum(MeetsGridLimit), numberOfDays);

fprintf('SOC-compliant days: %d of %d\n', ...
    sum(SOCWithinLimits), numberOfDays);

fprintf('Battery-power-compliant days: %d of %d\n', ...
    sum(BatteryPowerWithinRating), numberOfDays);

weekSOCDrift_pct = ...
    FinalSOC_pct(end) - InitialSOC_pct(1);

fprintf('Week-end SOC change relative to Day 1 initial SOC: %.3f percentage points\n', ...
    weekSOCDrift_pct);

%% 10. Save numerical results

csvFile = fullfile( ...
    resultsDir, ...
    'seven_day_sequential_results.csv');

matFile = fullfile( ...
    resultsDir, ...
    'seven_day_sequential_results.mat');

writetable(sevenDayResults, csvFile);

save(matFile, ...
    'sevenDayResults', ...
    'continuousTime_sec', ...
    'continuousSOC_pct', ...
    'continuousGridPower_kW', ...
    'continuousBatteryPower_kW', ...
    'E_batt_kWh', ...
    'P_batt_max_kW', ...
    'P_grid_limit_kW');

%% 11. Plot seven-day operation

continuousTime_days = ...
    continuousTime_sec / 86400;

figure( ...
    'Color', 'w', ...
    'Name', 'Seven-day PV-BESS Operation');

tiledlayout(3, 1, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');

% Continuous SOC
nexttile;

plot( ...
    continuousTime_days, ...
    continuousSOC_pct, ...
    'LineWidth', 1.8);

hold on;

yline(20, ...
    'r--', ...
    '20% SOC limit', ...
    'LineWidth', 1.2);

yline(25, ...
    'k--', ...
    '25% design target', ...
    'LineWidth', 1.2);

yline(90, ...
    'r--', ...
    '90% SOC limit', ...
    'LineWidth', 1.2);

for boundary = 1:6
    xline(boundary, ':', 'Color', [0.5 0.5 0.5]);
end

grid on;
box on;

xlim([0 7]);
xticks(0:7);

ylabel('SOC (%)');
title('Continuous Battery SOC');

% Continuous grid power
nexttile;

plot( ...
    continuousTime_days, ...
    continuousGridPower_kW, ...
    'LineWidth', 1.5);

hold on;

yline(100, ...
    'r--', ...
    '100 kW grid limit', ...
    'LineWidth', 1.5);

for boundary = 1:6
    xline(boundary, ':', 'Color', [0.5 0.5 0.5]);
end

grid on;
box on;

xlim([0 7]);
xticks(0:7);

ylabel('Grid power (kW)');
title('Continuous Grid Import');

% Daily final SOC
nexttile;

bar(DayNumber, FinalSOC_pct);

hold on;

yline(20, ...
    'r--', ...
    '20% SOC limit', ...
    'LineWidth', 1.2);

yline(25, ...
    'k--', ...
    '25% design target', ...
    'LineWidth', 1.2);

grid on;
box on;

xticks(DayNumber);
xlabel('Day');
ylabel('Final SOC (%)');
title('Daily Final SOC');

sgtitle( ...
    'Seven-day Sequential Operation of 340 kWh / 70 kW PV-BESS');

exportgraphics(gcf, ...
    fullfile(resultsDir, ...
    'seven_day_sequential_operation.png'), ...
    'Resolution', 300);

fprintf('\nResults saved to:\n%s\n', resultsDir);