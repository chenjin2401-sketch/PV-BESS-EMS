%% PV-BESS EMS project initialization
clc; close all;

% Locate project folders
scriptFolder = fileparts(mfilename('fullpath'));
projectRoot = fileparts(scriptFolder);

% Load input profiles
load(fullfile(projectRoot, 'data', 'load_profile.mat'));
load(fullfile(projectRoot, 'data', 'pv_profile.mat'));

% Configurable design parameters
E_batt_kWh = 200;          % Battery energy capacity
P_batt_max_kW = 50;        % Charge/discharge power rating
P_grid_limit_kW = 100;     % Peak-shaving target
precharge_enable = 0;     % 0: disabled, 1: enabled

fprintf('Project initialized:\n');
fprintf('Battery capacity: %.0f kWh\n', E_batt_kWh);
fprintf('Battery power: %.0f kW\n', P_batt_max_kW);
fprintf('Grid limit: %.0f kW\n', P_grid_limit_kW);