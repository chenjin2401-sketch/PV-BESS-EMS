%% compare_bess_designs.m
% Compare an economy BESS design with a higher-reliability design.

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

%% 2. Load the original profiles

loadData = load(fullfile(dataDir, 'load_profile.mat'));
pvData   = load(fullfile(dataDir, 'pv_profile.mat'));

baseLoad = loadData.load_profile.Data(:);
loadTime = loadData.load_profile.Time(:);

basePV = pvData.pv_profile.Data(:);
pvTime = pvData.pv_profile.Time(:);

assert(numel(baseLoad) == numel(basePV), ...
    'Load and PV profiles must contain the same number of samples.');

assert(max(abs(loadTime - pvTime)) < 1e-6, ...
    'Load and PV time vectors are different.');

simulationTime = loadTime;

%% 3. Define the two candidate BESS designs

designNames = [
    "Economy: 200 kWh / 50 kW"
    "Enhanced: 300 kWh / 70 kW"
];

capacityList_kWh = [200; 300];
powerList_kW     = [50; 70];

%% 4. Define operating scenarios

scenarioNames = [
    "Sunny / Normal Load"
    "Cloudy / Normal Load"
    "Sunny / High Load"
    "Cloudy / High Load"
];

pvScale = [
    1.00
    0.55
    1.00
    0.55
];

loadScale = [
    1.00
    1.00
    1.15
    1.15
];

% Same precharge policy used in the validated scenario study
prechargeFlags = [
    0
    1
    1
    1
];

P_grid_limit_kW = 100;

%% 5. Preallocate result arrays

numberOfDesigns   = numel(designNames);
numberOfScenarios = numel(scenarioNames);
numberOfCases     = numberOfDesigns * numberOfScenarios;

Design                 = strings(numberOfCases, 1);
Scenario               = strings(numberOfCases, 1);
Capacity_kWh           = zeros(numberOfCases, 1);
Power_kW               = zeros(numberOfCases, 1);
PrechargeEnable        = zeros(numberOfCases, 1);
BaselinePeak_kW        = zeros(numberOfCases, 1);
PeakGrid_kW            = zeros(numberOfCases, 1);
MeetsGridLimit         = false(numberOfCases, 1);
GridExceedance_kWh     = zeros(numberOfCases, 1);
PeakReduction_pct      = zeros(numberOfCases, 1);
MinSOC_pct             = zeros(numberOfCases, 1);
FinalSOC_pct           = zeros(numberOfCases, 1);
MaxSOC_pct             = zeros(numberOfCases, 1);

peakMatrix       = zeros(numberOfScenarios, numberOfDesigns);
exceedanceMatrix = zeros(numberOfScenarios, numberOfDesigns);
minSOCMatrix     = zeros(numberOfScenarios, numberOfDesigns);

%% 6. Run all eight cases

row = 0;

for designIndex = 1:numberOfDesigns

    for scenarioIndex = 1:numberOfScenarios

        row = row + 1;

        fprintf('\nRunning case %d of %d\n', row, numberOfCases);
        fprintf('Design: %s\n', designNames(designIndex));
        fprintf('Scenario: %s\n', scenarioNames(scenarioIndex));

        % Create the scenario profiles
        load_profile_case = timeseries( ...
            baseLoad * loadScale(scenarioIndex), simulationTime);

        pv_profile_case = timeseries( ...
            basePV * pvScale(scenarioIndex), simulationTime);

        % Put all model inputs into the MATLAB base workspace
        assignin('base', 'load_profile', load_profile_case);
        assignin('base', 'pv_profile', pv_profile_case);

        % Both naming styles are assigned so the script works with the
        % parameter names used in earlier versions of the model.
        assignin('base', 'E_batt', capacityList_kWh(designIndex));
        assignin('base', 'E_batt_kWh', capacityList_kWh(designIndex));

        assignin('base', 'P_batt_max', powerList_kW(designIndex));
        assignin('base', 'P_batt_max_kW', powerList_kW(designIndex));

        assignin('base', 'P_grid_limit', P_grid_limit_kW);
        assignin('base', 'P_grid_limit_kW', P_grid_limit_kW);

        assignin('base', 'precharge_enable', ...
            prechargeFlags(scenarioIndex));

        % Reduce Simulation Data Inspector disk usage
        Simulink.sdi.clear;

        % Run the model
        simOut = sim(modelName, ...
            'StopTime', '86400', ...
            'ReturnWorkspaceOutputs', 'on');

        % Read simulation outputs
        P_grid_base_ts = simOut.get('P_grid_base_sim');
        P_grid_ems_ts  = simOut.get('P_grid_ems_sim');
        SOC_ts         = simOut.get('SOC_sim');

        timeGrid  = P_grid_ems_ts.Time(:);
        PgridBase = P_grid_base_ts.Data(:);
        PgridEMS  = P_grid_ems_ts.Data(:);
        SOC       = SOC_ts.Data(:);

        assert(~isempty(PgridEMS), ...
            'P_grid_ems_sim is empty.');

        assert(~isempty(SOC), ...
            'SOC_sim is empty.');

        % KPI calculations
        baselinePeak = max(PgridBase);
        emsPeak      = max(PgridEMS);

        excessPower = max(PgridEMS - P_grid_limit_kW, 0);
        exceedanceEnergy = trapz(timeGrid, excessPower) / 3600;

        peakReduction = ...
            100 * (baselinePeak - emsPeak) / baselinePeak;

        % Store result
        Design(row)          = designNames(designIndex);
        Scenario(row)        = scenarioNames(scenarioIndex);
        Capacity_kWh(row)    = capacityList_kWh(designIndex);
        Power_kW(row)        = powerList_kW(designIndex);
        PrechargeEnable(row) = prechargeFlags(scenarioIndex);

        BaselinePeak_kW(row)    = baselinePeak;
        PeakGrid_kW(row)        = emsPeak;
        MeetsGridLimit(row)     = emsPeak <= P_grid_limit_kW + 0.01;
        GridExceedance_kWh(row) = exceedanceEnergy;
        PeakReduction_pct(row)  = peakReduction;

        MinSOC_pct(row)   = 100 * min(SOC);
        FinalSOC_pct(row) = 100 * SOC(end);
        MaxSOC_pct(row)   = 100 * max(SOC);

        peakMatrix(scenarioIndex, designIndex) = emsPeak;

        exceedanceMatrix(scenarioIndex, designIndex) = ...
            exceedanceEnergy;

        minSOCMatrix(scenarioIndex, designIndex) = ...
            100 * min(SOC);
    end
end

%% 7. Create the comparison table

designComparisonResults = table( ...
    Design, ...
    Scenario, ...
    Capacity_kWh, ...
    Power_kW, ...
    PrechargeEnable, ...
    BaselinePeak_kW, ...
    PeakGrid_kW, ...
    MeetsGridLimit, ...
    GridExceedance_kWh, ...
    PeakReduction_pct, ...
    MinSOC_pct, ...
    FinalSOC_pct, ...
    MaxSOC_pct);

fprintf('\n--- BESS Design Comparison Summary ---\n');

disp(designComparisonResults(:, { ...
    'Design', ...
    'Scenario', ...
    'PeakGrid_kW', ...
    'MeetsGridLimit', ...
    'GridExceedance_kWh', ...
    'MinSOC_pct', ...
    'FinalSOC_pct'}));

%% 8. Save results

csvFile = fullfile(resultsDir, ...
    'bess_design_comparison.csv');

matFile = fullfile(resultsDir, ...
    'bess_design_comparison.mat');

writetable(designComparisonResults, csvFile);

save(matFile, ...
    'designComparisonResults', ...
    'peakMatrix', ...
    'exceedanceMatrix', ...
    'minSOCMatrix');

%% 9. Plot peak grid import comparison

x = 1:numberOfScenarios;

figure('Color', 'w', ...
    'Name', 'BESS Design Peak Comparison');

barHandle = bar(x, peakMatrix, 'grouped');
hold on;

yline(P_grid_limit_kW, 'r--', ...
    '100 kW Grid Limit', ...
    'LineWidth', 1.8, ...
    'LabelHorizontalAlignment', 'right');

grid on;
box on;

xticks(x);
xticklabels(scenarioNames);
xtickangle(15);

ylabel('Peak grid import (kW)');
title('Peak Grid Import: Economy vs Enhanced BESS Design');

legend(designNames, ...
    'Location', 'northwest');

for designIndex = 1:numberOfDesigns
    text( ...
        barHandle(designIndex).XEndPoints, ...
        barHandle(designIndex).YEndPoints, ...
        compose('%.1f', ...
        barHandle(designIndex).YEndPoints), ...
        'HorizontalAlignment', 'center', ...
        'VerticalAlignment', 'bottom', ...
        'FontSize', 9);
end

exportgraphics(gcf, ...
    fullfile(resultsDir, ...
    'bess_design_peak_comparison.png'), ...
    'Resolution', 300);

%% 10. Plot reliability indicators

figure('Color', 'w', ...
    'Name', 'BESS Design Reliability Comparison');

tiledlayout(1, 2, ...
    'TileSpacing', 'compact', ...
    'Padding', 'compact');

nexttile;

bar(x, exceedanceMatrix, 'grouped');
grid on;
box on;

xticks(x);
xticklabels(scenarioNames);
xtickangle(20);

ylabel('Grid-limit exceedance energy (kWh)');
title('Energy Imported above 100 kW');
legend(designNames, 'Location', 'northwest');

nexttile;

bar(x, minSOCMatrix, 'grouped');
hold on;

yline(20, 'r--', ...
    '20% SOC limit', ...
    'LineWidth', 1.5);

grid on;
box on;

xticks(x);
xticklabels(scenarioNames);
xtickangle(20);

ylabel('Minimum SOC (%)');
title('Battery Reserve after Dispatch');
legend(designNames, 'Location', 'best');

exportgraphics(gcf, ...
    fullfile(resultsDir, ...
    'bess_design_reliability_comparison.png'), ...
    'Resolution', 300);

fprintf('\nResults saved to:\n%s\n', resultsDir);