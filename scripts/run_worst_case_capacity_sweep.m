%% run_worst_case_capacity_sweep.m
% Capacity adequacy study under Cloudy / High Load conditions.

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

%% 2. Load original profiles

loadData = load(fullfile(dataDir, 'load_profile.mat'));
pvData   = load(fullfile(dataDir, 'pv_profile.mat'));

time = loadData.load_profile.Time(:);

baseLoad = loadData.load_profile.Data(:);
basePV   = pvData.pv_profile.Data(:);

assert(numel(baseLoad) == numel(basePV), ...
    'Load and PV profiles must have the same length.');

%% 3. Define the worst-case operating scenario

loadScale = 1.15;
pvScale   = 0.55;

load_profile_case = timeseries(baseLoad * loadScale, time);
pv_profile_case   = timeseries(basePV * pvScale, time);

assignin('base', 'load_profile', load_profile_case);
assignin('base', 'pv_profile', pv_profile_case);

%% 4. Capacity sweep settings

capacityList_kWh = (300:10:450)';
P_batt_max_kW    = 70;
P_grid_limit_kW  = 100;

SOC_operating_limit_pct = 20;
SOC_design_margin_pct   = 25;

numberOfCases = numel(capacityList_kWh);

PeakGrid_kW        = zeros(numberOfCases, 1);
GridExceedance_kWh = zeros(numberOfCases, 1);
MinSOC_pct         = zeros(numberOfCases, 1);
FinalSOC_pct       = zeros(numberOfCases, 1);
RequiredPower_kW   = zeros(numberOfCases, 1);

%% 5. Run capacity sweep

for caseIndex = 1:numberOfCases

    currentCapacity = capacityList_kWh(caseIndex);

    fprintf('\nRunning capacity case %d of %d: %.0f kWh / %.0f kW\n', ...
        caseIndex, numberOfCases, ...
        currentCapacity, P_batt_max_kW);

    % Assign model parameters
    assignin('base', 'E_batt', currentCapacity);
    assignin('base', 'E_batt_kWh', currentCapacity);

    assignin('base', 'P_batt_max', P_batt_max_kW);
    assignin('base', 'P_batt_max_kW', P_batt_max_kW);

    assignin('base', 'P_grid_limit', P_grid_limit_kW);
    assignin('base', 'P_grid_limit_kW', P_grid_limit_kW);

    assignin('base', 'precharge_enable', 1);

    % Clear logged runs to reduce disk usage
    Simulink.sdi.clear;

    % Run simulation
    simOut = sim(modelName, ...
        'StopTime', '86400', ...
        'ReturnWorkspaceOutputs', 'on');

    % Extract outputs
    P_grid_base_ts = simOut.get('P_grid_base_sim');
    P_grid_ems_ts  = simOut.get('P_grid_ems_sim');
    SOC_ts         = simOut.get('SOC_sim');

    simulationTime = P_grid_ems_ts.Time(:);
    P_grid_base    = P_grid_base_ts.Data(:);
    P_grid_ems     = P_grid_ems_ts.Data(:);
    SOC            = SOC_ts.Data(:);

    assert(~isempty(P_grid_ems), ...
        'P_grid_ems_sim is empty.');

    assert(~isempty(SOC), ...
        'SOC_sim is empty.');

    % KPI calculations
    PeakGrid_kW(caseIndex) = max(P_grid_ems);

    excessPower = max(P_grid_ems - P_grid_limit_kW, 0);

    GridExceedance_kWh(caseIndex) = ...
        trapz(simulationTime, excessPower) / 3600;

    MinSOC_pct(caseIndex)   = 100 * min(SOC);
    FinalSOC_pct(caseIndex) = 100 * SOC(end);

    RequiredPower_kW(caseIndex) = ...
        max(P_grid_base) - P_grid_limit_kW;
end

%% 6. Determine feasibility and engineering margin

MeetsGridLimit = ...
    PeakGrid_kW <= P_grid_limit_kW + 0.01 & ...
    GridExceedance_kWh <= 0.01;

HasSOCMargin = ...
    MinSOC_pct >= SOC_design_margin_pct;

RecommendedDesign = ...
    MeetsGridLimit & HasSOCMargin;

capacitySweepResults = table( ...
    capacityList_kWh, ...
    PeakGrid_kW, ...
    GridExceedance_kWh, ...
    MinSOC_pct, ...
    FinalSOC_pct, ...
    MeetsGridLimit, ...
    HasSOCMargin, ...
    RecommendedDesign);

fprintf('\n--- Worst-case Capacity Sweep Summary ---\n');

disp(capacitySweepResults);

%% 7. Find minimum feasible and recommended capacities

firstFeasibleIndex = find(MeetsGridLimit, 1, 'first');
firstRecommendedIndex = find(RecommendedDesign, 1, 'first');

fprintf('\n--- Engineering Selection Result ---\n');

fprintf('Estimated peak discharge power required: %.1f kW\n', ...
    max(RequiredPower_kW));

if isempty(firstFeasibleIndex)

    fprintf(['No tested capacity satisfies the 100 kW grid limit. ' ...
        'Extend the capacity range.\n']);

else

    fprintf('Minimum technically feasible capacity: %.0f kWh\n', ...
        capacityList_kWh(firstFeasibleIndex));

end

if isempty(firstRecommendedIndex)

    fprintf(['No tested capacity provides both grid compliance ' ...
        'and 5%% SOC margin.\n']);

else

    fprintf(['Recommended capacity with at least 5%% ' ...
        'SOC operating margin: %.0f kWh\n'], ...
        capacityList_kWh(firstRecommendedIndex));

end

%% 8. Save results

csvFile = fullfile(resultsDir, ...
    'worst_case_capacity_sweep.csv');

matFile = fullfile(resultsDir, ...
    'worst_case_capacity_sweep.mat');

writetable(capacitySweepResults, csvFile);

save(matFile, ...
    'capacitySweepResults', ...
    'P_batt_max_kW', ...
    'P_grid_limit_kW');

%% 9. Plot sizing results

figure( ...
    'Color', 'w', ...
    'Name', 'Worst-case BESS Capacity Sizing');

tiledlayout(1, 3, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');

% Peak grid import
nexttile;

plot(capacityList_kWh, PeakGrid_kW, ...
    'o-', ...
    'LineWidth', 2, ...
    'MarkerSize', 6);

hold on;

yline(P_grid_limit_kW, ...
    'r--', ...
    '100 kW limit', ...
    'LineWidth', 1.5);

grid on;
box on;

xlabel('Battery capacity (kWh)');
ylabel('Peak grid import (kW)');
title('Peak Demand Compliance');

% Grid-limit exceedance energy
nexttile;

plot(capacityList_kWh, GridExceedance_kWh, ...
    's-', ...
    'LineWidth', 2, ...
    'MarkerSize', 6);

hold on;

yline(0, 'r--', 'No exceedance');

grid on;
box on;

xlabel('Battery capacity (kWh)');
ylabel('Exceedance energy (kWh)');
title('Grid-limit Violation');

% Minimum SOC
nexttile;

plot(capacityList_kWh, MinSOC_pct, ...
    'd-', ...
    'LineWidth', 2, ...
    'MarkerSize', 6);

hold on;

yline(SOC_operating_limit_pct, ...
    'r--', ...
    '20% operating limit', ...
    'LineWidth', 1.5);

yline(SOC_design_margin_pct, ...
    'k--', ...
    '25% design target', ...
    'LineWidth', 1.5);

grid on;
box on;

xlabel('Battery capacity (kWh)');
ylabel('Minimum SOC (%)');
title('Battery Energy Margin');

sgtitle( ...
    'BESS Capacity Adequacy under Cloudy / High Load Scenario');

exportgraphics(gcf, ...
    fullfile(resultsDir, ...
    'worst_case_capacity_sizing.png'), ...
    'Resolution', 300);

fprintf('\nResults saved to:\n%s\n', resultsDir);