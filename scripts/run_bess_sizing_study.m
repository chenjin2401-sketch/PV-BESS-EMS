%% BESS sizing study
clc; close all;
% Prevent Simulation Data Inspector disk-space problems
Simulink.sdi.clear(Export=false);
Simulink.sdi.setStorageMode("memory");
Simulink.sdi.setRecordData(true);

% Project folders
scriptFolder = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptFolder);
dataFolder = fullfile(projectRoot, 'data');
modelFolder = fullfile(projectRoot, 'model');
resultsFolder = fullfile(projectRoot, 'results');

% Load model input profiles into the MATLAB workspace
load(fullfile(dataFolder, 'pv_profile.mat'), ...
    'pv_profile', 'P_PV', 'E_PV_kWh');
load(fullfile(dataFolder, 'pv_profile.mat'), ...
    'pv_profile', 'P_PV', 'E_PV_kWh');
% Load Simulink model
modelName = 'PV_BESS_EMS';
modelFile = fullfile(modelFolder, [modelName '.slx']);

load_system(modelFile);
set_param(modelName, 'FastRestart', 'off');

% Design options
capacityList = [100 200 300];     % kWh
powerList = [30 50 70];           % kW

P_grid_limit_kW = 100;

% Fixed battery assumptions
eta_ch = 0.95;
eta_dis = 0.95;

nCapacity = numel(capacityList);
nPower = numel(powerList);
nCases = nCapacity * nPower;

% Result storage
Capacity_kWh = zeros(nCases, 1);
Power_kW = zeros(nCases, 1);
PeakGrid_kW = zeros(nCases, 1);
PeakReduction_pct = zeros(nCases, 1);
GridImport_kWh = zeros(nCases, 1);
AdjustedGridImport_kWh = zeros(nCases, 1);
AdjustedImportReduction_pct = zeros(nCases, 1);
PVSelfConsumption_pct = zeros(nCases, 1);
InitialSOC_pct = zeros(nCases, 1);
FinalSOC_pct = zeros(nCases, 1);
MinSOC_pct = zeros(nCases, 1);
MaxSOC_pct = zeros(nCases, 1);
TerminalCorrection_kWh = zeros(nCases, 1);
MeetsGridLimit = false(nCases, 1);

PeakGridMatrix = zeros(nCapacity, nPower);
AdjustedReductionMatrix = zeros(nCapacity, nPower);

caseIndex = 0;

for i = 1:nCapacity
    for j = 1:nPower

        caseIndex = caseIndex + 1;

        % Parameters used by Constant blocks in Simulink
        E_batt_kWh = capacityList(i);
        P_batt_max_kW = powerList(j);

        fprintf('\nRunning case %d of %d: %.0f kWh / %.0f kW\n', ...
            caseIndex, nCases, E_batt_kWh, P_batt_max_kW);

        % Remove the previous temporary run before starting a new case
        Simulink.sdi.clear(Export=false);
        Simulink.sdi.setRecordData(true);

        % Run simulation
        simOut = sim(modelName, 'StopTime', '86400');

        % Extract To Workspace results
        P_grid_base_ts = simOut.P_grid_base_sim;
        P_grid_ems_ts = simOut.P_grid_ems_sim;
        P_batt_ts = simOut.P_batt_sim;
        SOC_ts = simOut.SOC_sim;

        time = P_grid_base_ts.Time;

        P_grid_base = P_grid_base_ts.Data(:);
        P_grid_ems = P_grid_ems_ts.Data(:);
        P_batt = P_batt_ts.Data(:);
        SOC = SOC_ts.Data(:);
        if isempty(SOC)
            error(['SOC output is empty. ', ...
                'Simulation data recording was not completed.']);
        end

        % Basic metrics
        peakBase = max(P_grid_base);
        peakEMS = max(P_grid_ems);

        gridImportBase = ...
            trapz(time, max(P_grid_base, 0)) / 3600;

        gridImportEMS = ...
            trapz(time, max(P_grid_ems, 0)) / 3600;

        gridExportEMS = ...
            trapz(time, max(-P_grid_ems, 0)) / 3600;

        pvEnergy = E_PV_kWh;

        pvSelfConsumption = ...
            100 * (pvEnergy - gridExportEMS) / pvEnergy;

        % Terminal SOC correction
        socInitial = SOC(1);
        socFinal = SOC(end);

        if socFinal < socInitial
            % Additional grid energy needed to restore initial SOC
            terminalCorrection = ...
                (socInitial - socFinal) ...
                * E_batt_kWh / eta_ch;
        else
            % Credit remaining stored energy at discharge efficiency
            terminalCorrection = ...
                -(socFinal - socInitial) ...
                * E_batt_kWh * eta_dis;
        end

        adjustedGridImport = ...
            gridImportEMS + terminalCorrection;

        adjustedImportReduction = 100 * ...
            (gridImportBase - adjustedGridImport) ...
            / gridImportBase;

        % Store results
        Capacity_kWh(caseIndex) = E_batt_kWh;
        Power_kW(caseIndex) = P_batt_max_kW;
        PeakGrid_kW(caseIndex) = peakEMS;

        PeakReduction_pct(caseIndex) = ...
            100 * (peakBase - peakEMS) / peakBase;

        GridImport_kWh(caseIndex) = gridImportEMS;
        AdjustedGridImport_kWh(caseIndex) = adjustedGridImport;

        AdjustedImportReduction_pct(caseIndex) = ...
            adjustedImportReduction;

        PVSelfConsumption_pct(caseIndex) = ...
            pvSelfConsumption;

        InitialSOC_pct(caseIndex) = socInitial * 100;
        FinalSOC_pct(caseIndex) = socFinal * 100;
        MinSOC_pct(caseIndex) = min(SOC) * 100;
        MaxSOC_pct(caseIndex) = max(SOC) * 100;

        TerminalCorrection_kWh(caseIndex) = ...
            terminalCorrection;

        MeetsGridLimit(caseIndex) = ...
            peakEMS <= P_grid_limit_kW + 0.01;

        PeakGridMatrix(i, j) = peakEMS;
        AdjustedReductionMatrix(i, j) = ...
            adjustedImportReduction;
    end
end

% Assemble result table
sizingResults = table( ...
    Capacity_kWh, Power_kW, ...
    PeakGrid_kW, PeakReduction_pct, ...
    MeetsGridLimit, ...
    GridImport_kWh, AdjustedGridImport_kWh, ...
    AdjustedImportReduction_pct, ...
    PVSelfConsumption_pct, ...
    InitialSOC_pct, FinalSOC_pct, ...
    MinSOC_pct, MaxSOC_pct, ...
    TerminalCorrection_kWh);

% Display most important columns
fprintf('\n--- BESS Sizing Study Summary ---\n');

disp(sizingResults(:, { ...
    'Capacity_kWh', ...
    'Power_kW', ...
    'PeakGrid_kW', ...
    'MeetsGridLimit', ...
    'FinalSOC_pct', ...
    'PVSelfConsumption_pct', ...
    'AdjustedImportReduction_pct'}));

% Save data
writetable(sizingResults, ...
    fullfile(resultsFolder, 'bess_sizing_results.csv'));

save(fullfile(resultsFolder, 'bess_sizing_results.mat'), ...
    'sizingResults', ...
    'PeakGridMatrix', ...
    'AdjustedReductionMatrix', ...
    'capacityList', 'powerList');

% Heatmap 1: peak grid import
fig1 = figure('Color', 'w');

h1 = heatmap( ...
    string(powerList), ...
    string(capacityList), ...
    PeakGridMatrix);

h1.Title = 'Peak Grid Import for Different BESS Sizes';
h1.XLabel = 'Battery Power Rating (kW)';
h1.YLabel = 'Battery Energy Capacity (kWh)';
h1.CellLabelFormat = '%.1f';

exportgraphics(fig1, ...
    fullfile(resultsFolder, ...
    'bess_sizing_peak_grid_heatmap.png'), ...
    'Resolution', 300);

% Heatmap 2: adjusted grid-energy reduction
fig2 = figure('Color', 'w');

h2 = heatmap( ...
    string(powerList), ...
    string(capacityList), ...
    AdjustedReductionMatrix);

h2.Title = 'SOC-adjusted Grid Import Reduction (%)';
h2.XLabel = 'Battery Power Rating (kW)';
h2.YLabel = 'Battery Energy Capacity (kWh)';
h2.CellLabelFormat = '%.1f';

exportgraphics(fig2, ...
    fullfile(resultsFolder, ...
    'bess_sizing_energy_reduction_heatmap.png'), ...
    'Resolution', 300);

fprintf('\nSizing study completed.\n');
fprintf('Results saved in: %s\n', resultsFolder);