function [probSun, skyData, shadowsData, wallsData, pedsData] = ...
    estimateIllumination(img, focalLength, horizonLine, varargin)
% Estimates the illumination parameters given an image.
%
%   estimateIllumination(...)
% 
%   If horizonLine = [], it will be estimated from the geometric context
%   labels.
%
% ----------
% Jean-Francois Lalonde

% parse arguments
defaultArgs = struct('DoEstimateHorizon', 0, 'DoVote', 0, 'DoWeightVote', 0, 'DoCueConfidence', 0, ...
    'DoSky', 1, 'SkyPredictor', [], 'DoSkyClassif', 0, 'SkyDb', [], ...
    'DoShadows', 1, 'ShadowsPredictor', [], ...
    'DoWalls', 1, 'WallPredictor', [], ...
    'DoPedestrians', 1, 'PedestrianPredictor', []);
args = parseargs(defaultArgs, varargin{:});


%% Geometric context information
geomContextInfo = load(fullfile(args.DbPath, imgInfo.geomContext.filename));

%% Do we need to estimate the horizon?
if isempty(horizonLine)
    horizonLine = horizonFromGeometricContext(geomContextInfo.allSkyMask>0.5, geomContextInfo.allGroundMask>0.5);
end

%% Estimate illumination using sky
if args.DoSky
    [skyData.probSun, skyData.label, skyData.area] = estimateIlluminationFromSky(img, args.SkyPredictor, geomContextInfo.allSkyMask, geomContextInfo.segImage, ...
        focalLength, horizonLine, 'DoSkyClassif', args.DoSkyClassif, 'SkyDb', args.SkyDb);
else
    % uniform
    skyData.probSun = args.SkyPredictor.constantProb();
    skyData.label = 'noestimate';
    skyData.area = 0;
end

%% Shadows
if args.DoShadows
    bndInfo = load(fullfile(args.DbPath, imgInfo.wseg25.filename));
    shadowInfo = load(fullfile(args.DbPath, imgInfo.shadows.filename));
    
    if args.DoCueConfidence
        % keep all boundaries (strong)
%         shadowBoundaries = bndInfo.boundaries(shadowInfo.indStrongBnd);
        shadowBoundaries = bndInfo.boundaries(shadowInfo.boundaryLabels==0);
    else
        % only keep most likely boundaries
        shadowPrecisionThresh = 0.75;
        shadowBoundaries = bndInfo.boundaries(shadowInfo.allBoundaryProbabilities>shadowPrecisionThresh);
%         shadowBoundaries = bndInfo.boundaries(shadowInfo.boundaryLabels==0);
    end
    
    % force the ground to be zero below the horizon
    [m,mind] = max(cat(3, geomContextInfo.allGroundMask, geomContextInfo.allSkyMask, geomContextInfo.allWallsMask), [], 3);
    groundMask = imdilate(mind==1, strel('disk', 3));
    groundMask(1:ceil(horizonLine+1),:) = 0;
    
    % make sure shadows are on the ground (apply geometric context mask)
    meanGroundProb = interpBoundarySubPixel(shadowBoundaries, groundMask);
    shadowBoundaries = shadowBoundaries(meanGroundProb > 0.5);
    
    if ~isempty(shadowBoundaries)
        shadowLines = extractLinesFromBoundaries(img, shadowBoundaries);
        
        % concatenate probabilty of shadow in the last column of shadowLines
        probImg = zeros(size(img,1), size(img,2));
        for i=shadowInfo.indStrongBnd(:)'
            boundariesPxInd = convertBoundariesToPxInd(bndInfo.boundaries(i), size(img));
            probImg(boundariesPxInd) = shadowInfo.allBoundaryProbabilities(i);
        end
        
        shadowProbs = meanLineIntensity(probImg, shadowLines, 1);
        shadowLines = cat(2, shadowLines, shadowProbs);
        
        shadowsData.probSun = estimateIlluminationFromShadows(img, args.ShadowsPredictor, shadowLines, ...
            focalLength, horizonLine, 'DoVote', args.DoVote, 'DoWeightVote', args.DoWeightVote, 'DoCueConfidence', args.DoCueConfidence);
        shadowsData.lines = shadowLines;
    else
        shadowsData.probSun = args.ShadowsPredictor.constantProb();
        shadowsData.lines = [];
    end
else
    shadowsData.probSun = args.ShadowsPredictor.constantProb();
    shadowsData.lines = [];
end

%% Walls
if args.DoWalls
    % geom context is flipped wrt our convention: left <-> right
    [wallsData.probSun, wallsData.area, allWallsProbSun] = estimateIlluminationFromWalls(img, args.WallPredictor, ...
        geomContextInfo.wallRight, geomContextInfo.wallFacing, geomContextInfo.wallLeft, ...
        'DoVote', args.DoVote, 'DoWeightVote', args.DoWeightVote, 'DoCueConfidence', args.DoCueConfidence);
else
    wallsData.probSun = args.WallPredictor.constantProb();
    wallsData.area = 0;
end

%% Pedestrians
if args.DoPedestrians
    % load object information
    detInfo = load(fullfile(args.DbPath, imgInfo.detObjects.person.filename));
    [pedsData.probSun, pedsData.nb, allPedsProbSun] = estimateIlluminationFromPedestrians(img, args.PedestrianPredictor, ...
        detInfo.pObj, detInfo.pLocalVisibility, ...
        detInfo.pLocalLightingGivenObject, detInfo.pLocalLightingGivenNonObject, ...
        'DoVote', args.DoVote, 'DoWeightVote', args.DoWeightVote, 'DoCueConfidence', args.DoCueConfidence);
else
    pedsData.probSun = args.PedestrianPredictor.constantProb();
    pedsData.nb = 0;
end

%% Combine everything together
probSun = cat(3, skyData.probSun, shadowsData.probSun, wallsData.probSun, pedsData.probSun);
probSun = prod(probSun, 3);
probSun = probSun./sum(probSun(:));
